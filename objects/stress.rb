# Copyright (c) 2018 Yegor Bugayenko
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'zold/key'
require 'zold/id'
require 'zold/commands/create'
require 'zold/commands/pull'
require 'zold/commands/push'
require 'zold/commands/pay'
require 'zold/commands/remove'
require 'zold/verbose_thread'
require_relative 'stats'

#
# The stress tester.
#
class Stress
  # Number of wallets to work with
  POOL_SIZE = 8

  # Amount to send in each payment
  AMOUNT = Zold::Amount.new(zld: 0.01)

  # Delay between payment cycles, in seconds
  DELAY = 60

  def initialize(id:, pub:, pvt:, wallets:, remotes:, copies:, network: 'test', log: Zold::Log::Quiet.new)
    raise 'Wallet ID can\'t be nil' if id.nil?
    raise 'Wallet ID must be of type Id' unless id.is_a?(Zold::Id)
    @id = id
    raise 'Public RSA key can\'t be nil' if pub.nil?
    raise 'Public RSA key must be of type Key' unless pub.is_a?(Zold::Key)
    @pub = pub
    raise 'Private RSA key can\'t be nil' if pvt.nil?
    raise 'Private RSA key must be of type Key' unless pvt.is_a?(Zold::Key)
    @pvt = pvt
    raise 'Wallets can\'t be nil' if wallets.nil?
    @wallets = wallets
    raise 'Remotes can\'t be nil' if remotes.nil?
    @remotes = remotes
    raise 'Copies can\'t be nil' if copies.nil?
    @copies = copies
    raise 'Network can\'t be nil' if network.nil?
    @network = network
    raise 'Log can\'t be nil' if log.nil?
    @log = log
    @stats = Stats.new
    @payments = {}
  end

  def to_json
    {
      'wallets': @wallets.all.count,
      'thread': @thread ? @thread.status : '-',
      'waiting': @payments.count
    }.merge(@stats.to_json)
  end

  def start
    @thread = Thread.new do
      @log.info('Stress thread started')
      loop do
        @log.info('Stress thread cycle started...')
        start = Time.now
        Zold::VerboseThread.new(@log).run(true) do
          reload
          pay
          refetch
          match
          @log.info("Cycle done in #{Time.now - start}s, #{@wallets.all.count} wallets in the pool")
          sleep(Stress::DELAY)
        end
        @stats.put('cycles', Time.now - start)
      end
    end
  end

  def reload
    pull(@id)
    loop do
      pulled = 0
      @wallets.all.shuffle.each do |id|
        @wallets.find(Zold::Id.new(id)) do |w|
          w.txns.each do |t|
            next unless t.amount.negative?
            next if @wallets.all.include?(t.bnf.to_s)
            next if @wallets.all.count > Stress::POOL_SIZE
            pulled += pull(t.bnf)
          end
        end
      end
      break if pulled.zero?
    end
    @wallets.all.each do |id|
      next if @wallets.find(Zold::Id.new(id), &:balance) > Stress::AMOUNT
      Zold::Remove.new(wallets: @wallets, log: @log).run(
        ['remove']
      )
    end
    Tempfile.open do |f|
      File.write(f, @pub.to_s)
      while @wallets.all.count < Stress::POOL_SIZE
        Zold::Create.new(wallets: @wallets, log: @log).run(
          ['create', "--network=#{@network}", "--public-key=#{f.path}"]
        )
      end
    end
    while @wallets.all.count > Stress::POOL_SIZE
      Zold::Remove.new(wallets: @wallets, log: @log).run(
        ['remove', @wallets.all.sample.to_s]
      )
    end
  end

  def pay
    raise 'Too few wallets in the pool' if @wallets.all.count < 2
    seen = []
    loop do
      first, second = @wallets.all.sample(2)
      next if seen.include?(first)
      seen << first
      next if @wallets.find(Zold::Id.new(first), &:balance) < Stress::AMOUNT
      details = SecureRandom.uuid
      Tempfile.open do |f|
        File.write(f, @pvt.to_s)
        Zold::Pay.new(wallets: @wallets, remotes: @remotes, log: @log).run(
          ['pay', first, second, Stress::AMOUNT.to_zld, details, "--network=#{@network}", "--private-key=#{f.path}"]
        )
      end
      push(Zold::Id.new(first))
      @stats.put('paid', Stress::AMOUNT.to_zld)
      @payments[details] = Time.now
      break
    end
  end

  def refetch
    @wallets.all.each do |id|
      Zold::Remove.new(wallets: @wallets, log: @log).run(
        ['remove']
      )
      pull(Zold::Id.new(id))
    end
  end

  def match
    @wallets.all.each do |id|
      @wallets.find(Zold::Id.new(id)) do |w|
        w.txns.each do |t|
          next if t.amount.negative?
          next unless @payments[t.details]
          @stats.put('arrived', Time.now - @payments[t.details])
          @payments.delete(t.details)
        end
      end
    end
  end

  private

  def pull(id)
    start = Time.now
    Zold::Pull.new(wallets: @wallets, remotes: @remotes, copies: @copies, log: @log).run(
      ['pull', id.to_s, "--network=#{@network}"]
    )
    @stats.put('pull-ok', Time.now - start)
    1
  rescue StandardError => e
    @log.error(e.message)
    @stats.put('pull-error', Time.now - start)
    0
  end

  def push(id)
    start = Time.now
    Zold::Push.new(wallets: @wallets, remotes: @remotes, log: @log).run(
      ['push', id.to_s, "--network=#{@network}"]
    )
    @stats.put('push-ok', Time.now - start)
    1
  rescue StandardError => e
    @log.error(e.message)
    @stats.put('push-error', Time.now - start)
    0
  end
end
