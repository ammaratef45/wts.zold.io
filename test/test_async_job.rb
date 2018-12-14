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
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'minitest/autorun'
require 'concurrent'
require 'tmpdir'
require_relative 'test__helper'
require_relative '../objects/async_job'

class AsyncJobTest < Minitest::Test
  def test_pull
    pool = Concurrent::FixedThreadPool.new(16)
    Dir.mktmpdir 'test' do |dir|
      ops = AsyncJob.new(nil, pool, File.join(dir, 'lock'))
      ops.call
      pool.shutdown
      pool.wait_for_termination
    end
  end

  def test_prevents_multiple_threads_per_user
    pool = Concurrent::FixedThreadPool.new(16)
    Dir.mktmpdir 'test' do |dir|
      job = Object.new
      def job.call
        sleep 1000
      end
      async = AsyncJob.new(job, pool, File.join(dir, 'lock'))
      async.call
      sleep 0.1
      assert_raises UserError do
        async.call
      end
      pool.shutdown
      pool.wait_for_termination(1)
    end
  end
end
