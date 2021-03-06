# frozen_string_literal: true

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
require 'json'
require 'time'
require 'securerandom'
require_relative '../test__helper'
require_relative 'fake_node'
require_relative '../fake_home'
require_relative '../../lib/zold/http'
require_relative '../../lib/zold/json_page'
require_relative '../../lib/zold/score'

class FrontTest < Minitest::Test
  def test_renders_public_pages
    FakeNode.new(log: test_log).run(['--ignore-score-weakness']) do |port|
      {
        '200' => [
          '/robots.txt',
          '/',
          '/remotes',
          '/version',
          '/farm',
          '/metronome',
          '/score',
          '/trace'
        ],
        '404' => [
          '/this-is-absent',
          '/wallet/ffffeeeeddddcccc'
        ]
      }.each do |code, paths|
        paths.each do |p|
          uri = URI("http://localhost:#{port}#{p}")
          response = Zold::Http.new(uri: uri, score: nil).get
          assert_equal(
            code, response.code,
            "Invalid response code for #{uri}: #{response.message}"
          )
        end
      end
    end
  end

  def test_updates_list_of_remotes
    FakeNode.new(log: test_log).run(['--ignore-score-weakness']) do |port|
      score = Zold::Score.new(
        time: Time.now, host: 'localhost', port: port, invoice: 'NOPREFIX@ffffffffffffffff', strength: 1
      ).next.next.next.next
      response = Zold::Http.new(uri: "http://localhost:#{port}/remotes", score: score).get
      assert_equal('200', response.code, response.body)
      assert_equal(1, Zold::JsonPage.new(response.body).to_hash['all'].count, response.body)
    end
  end

  def test_renders_wallet_pages
    FakeHome.new.run do |home|
      FakeNode.new(log: test_log).run(['--ignore-score-weakness', '--standalone']) do |port|
        wallet = home.create_wallet
        test_log.debug("Wallet created: #{wallet.id}")
        base = "http://localhost:#{port}"
        response = Zold::Http.new(uri: "#{base}/wallet/#{wallet.id}", score: nil)
          .put(File.read(wallet.path))
        assert_equal('200', response.code, response.body)
        sleep 0.1 until Zold::Http.new(uri: "#{base}/wallet/#{wallet.id}", score: nil).get.code == '200'
        [
          "/wallet/#{wallet.id}.txt",
          "/wallet/#{wallet.id}.json",
          "/wallet/#{wallet.id}/balance",
          "/wallet/#{wallet.id}/key",
          "/wallet/#{wallet.id}/mtime",
          "/wallet/#{wallet.id}/digest",
          "/wallet/#{wallet.id}.bin",
          "/wallet/#{wallet.id}/copies"
        ].each do |u|
          res = Zold::Http.new(uri: "#{base}#{u}", score: nil).get
          assert_equal('200', res.code, res.body)
        end
      end
    end
  end

  def test_pushes_twice
    FakeNode.new(log: test_log).run do |port|
      FakeHome.new.run do |home|
        wallet = home.create_wallet
        base = "http://localhost:#{port}"
        response = Zold::Http.new(uri: "#{base}/wallet/#{wallet.id}", score: nil)
          .put(File.read(wallet.path))
        assert_equal('200', response.code, response.body)
        sleep 0.1 until Zold::Http.new(uri: "#{base}/wallet/#{wallet.id}", score: nil).get.code == '200'
        3.times do
          r = Zold::Http.new(uri: "#{base}/wallet/#{wallet.id}", score: nil)
            .put(File.read(wallet.path))
          assert_equal('304', r.code, r.body)
        end
      end
    end
  end

  def test_different_logos
    {
      '0' => 'https://www.zold.io/images/logo-red.png',
      '4' => 'https://www.zold.io/images/logo-orange.png',
      '16' => 'https://www.zold.io/images/logo-green.png'
    }.each do |num, path|
      test_log.info("Calculating score #{num}...")
      score = Zold::Score.new(
        time: Time.now, host: 'localhost', port: 999,
        invoice: 'NOPREFIX@ffffffffffffffff',
        strength: 1
      )
      num.to_i.times do
        score = score.next
      end
      test_log.info("Score #{num} calculated.")
      if score.value >= 16
        assert_equal(
          path, 'https://www.zold.io/images/logo-green.png',
          "Expected #{path} for score #{score.value}"
        )
      elsif score.value >= 4
        assert_equal(
          path, 'https://www.zold.io/images/logo-orange.png',
          "Expected #{path} for score #{score.value}"
        )
      else
        assert_equal(
          path, 'https://www.zold.io/images/logo-red.png',
          "Expected #{path} for score #{score.value}"
        )
      end
    end
  end

  def test_gzip
    FakeNode.new(log: test_log).run(['--ignore-score-weakness']) do |port|
      response = Zold::Http.new(uri: URI("http://localhost:#{port}/"), score: nil).get
      assert_equal(
        '200', response.code,
        "Expected HTTP 200 OK: Found #{response.code}"
      )
      assert_operator(
        750, :>, response['content-length'].to_i,
        'Expected the content to be smaller than 600 bytes for gzip'
      )
    end
  end

  def test_performance
    start = Time.now
    total = 50
    FakeNode.new(log: test_log).run(['--threads=4', '--strength=6', '--no-metronome']) do |port|
      total.times do
        Zold::Http.new(uri: URI("http://localhost:#{port}/"), score: nil).get
      end
    end
    sec = (Time.now - start) / total
    test_log.info("Average response time is #{sec.round(2)}s")
  end

  def app
    Zold::Front
  end

  def test_headers_are_being_set_correctly
    Time.stub :now, Time.at(0) do
      FakeNode.new(log: test_log).run(['--ignore-score-weakness']) do |port|
        response = Zold::Http.new(uri: URI("http://localhost:#{port}/"), score: nil).get
        assert_equal(
          'no-cache',
          response.header['Cache-Control']
        )
        assert_equal(
          'close',
          response.header['Connection']
        )
        assert_equal(
          app.settings.version,
          response.header['X-Zold-Version']
        )
        assert_equal(
          app.settings.protocol.to_s,
          response.header[Zold::Http::PROTOCOL_HEADER]
        )
        assert_equal(
          '*',
          response.header['Access-Control-Allow-Origin']
        )
        score = Zold::Score.new(
          time: Time.now, host: 'localhost', port: port, invoice: 'NOPREFIX@ffffffffffffffff', strength: 2
        )
        assert_equal(
          score.to_s,
          response.header[Zold::Http::SCORE_HEADER]
        )
      end
    end
  end

  def test_alias_parameter
    name = SecureRandom.hex(4)
    FakeNode.new(log: test_log).run(['--ignore-score-weakness', "--alias=#{name}"]) do |port|
      [
        '/',
        '/remotes'
      ].each do |path|
        uri = URI("http://localhost:#{port}#{path}")
        response = Zold::Http.new(uri: uri, score: nil).get
        assert_match(
          name,
          Zold::JsonPage.new(response.body).to_hash['alias'].to_s,
          response.body
        )
      end
    end
  end

  def test_default_alias_parameter
    FakeNode.new(log: test_log).run(['--ignore-score-weakness']) do |port|
      uri = URI("http://localhost:#{port}/")
      response = Zold::Http.new(uri: uri, score: nil).get
      assert_match(
        "localhost:#{port}",
        Zold::JsonPage.new(response.body).to_hash['alias'].to_s,
        response.body
      )
    end
  end

  def test_invalid_alias
    exception = assert_raises RuntimeError do
      FakeNode.new(log: test_log).run(['--ignore-score-weakness', '--alias=invalid-alias']) do |port|
        uri = URI("http://localhost:#{port}/")
        Zold::Http.new(uri: uri, score: nil).get
      end
    end
    assert_equal('--alias should be a 4 to 16 char long alphanumeric string', exception.message)
  end
end
