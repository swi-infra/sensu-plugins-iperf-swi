#!/usr/bin/env ruby
# encoding: utf-8

require 'json'
require 'sensu-plugin/metric/cli'
require 'rest-client'
require 'open3'

JSONRuby = JSON.dup

class IperfSwiCli < Sensu::Plugin::Metric::CLI::Influxdb

  option :api,
         short: '-a URL',
         long: '--api URL',
         description: 'Sensu API URL',
         default: 'http://localhost:4567'

  option :user,
         short: '-u USER',
         long: '--user USER',
         description: 'Sensu API USER'

  option :password,
         short: '-p PASSOWRD',
         long: '--password PASSWORD',
         description: 'Sensu API PASSWORD'

  option :timeout,
         short: '-t SECONDS',
         long: '--timeout SECONDS',
         description: 'Sensu API connection timeout in SECONDS',
         proc: proc(&:to_i),
         default: 30

  option :iperf_path,
         short: '-b BIN',
         long: '--iperf-path BIN',
         description: 'Path to iperf 3',
         default: "iperf3"

  option :iperf_opts,
         short: '-i IPERF',
         long: '--iperf-options IPERF',
         description: 'Command-line options to run with iperf',
         default: "-t 10"

  def api_request(resource)
    request = RestClient::Resource.new(config[:api] + resource, timeout: config[:timeout],
                                                                user: config[:user],
                                                                password: config[:password])
    JSONRuby.parse(request.get, symbolize_names: true)
  rescue RestClient::ResourceNotFound
    warning "Resource not found: #{resource}"
  rescue Errno::ECONNREFUSED
    warning 'Connection refused'
  rescue RestClient::RequestFailed
    warning 'Request failed'
  rescue RestClient::RequestTimeout
    warning 'Connection timed out'
  rescue RestClient::Unauthorized
    warning 'Missing or incorrect Sensu API credentials'
  rescue JSONRuby::ParserError
    warning 'Sensu API returned invalid JSON'
  end

  def clients
    @clients ||= api_request("/clients")
  end

  def hostname_to_site(name)
    name[/^([a-z]*)-/i, 1].downcase.to_sym
  end

  def clients_per_site
    if @clients_per_site.nil?
      @clients_per_site = {}
      clients.each.map do |client|
        client_name = client[:name]
        s = hostname_to_site(client_name)

        # Only consider clients that also have the 'iperf' subscription
        next unless client[:subscriptions].include? "iperf"

        @clients_per_site[s] ||= {}
        @clients_per_site[s][client_name] = client
      end
    end

    @clients_per_site
  end

  def current_site
    hostname_to_site(Socket.gethostname)
  end

  def sites
    clients_per_site.keys
  end

  def client_from_site(site)
    return nil unless clients_per_site[site]
    clients_per_site[site].values.sample
  end

  def measure_host(site, hostname, ip)
    output = `#{config[:iperf_path]} --json -c #{ip} #{config[:iperf_opts]}`

    res = JSONRuby.parse(output, symbolize_names: true)

    # The iperf server can only serve one client at a time, so sometimes
    # it will fail.
    unless res[:end] and res[:end][:sum_received]
      STDERR.puts "Unable to test #{hostname} (#{ip}): #{res}"
      return  false
    end

    output "iperf.site.bits_per_second", res[:end][:sum_received][:bits_per_second],
           "from_site=#{current_site},to_site=#{site}"
    output "iperf.host.#{hostname}.tx.bits_per_second", res[:end][:sum_received][:bits_per_second]

    return true
  end

  def run
    sites.each do |site|
      next if site == current_site

      client = client_from_site(site)
      name = client[:name]
      ip = client[:address]

      # Retry up to 10 times
      10.times do
        break if measure_host(site, name, ip)

        sleep 15
      end
    end

    ok
  end
end
