#!/bin/sh
# DO NOT USE THIS SCRIPT
# It uses APIs that are not yet documented and are not yet finalized.
# Also, it is incomplete because I wam waiting for such public-documentation.
# TODO(sissel): see if we can just make this a ruby script, not shell calling ruby.

progname=$(basename $0)
log() {
  logger -st $progname "$@"
}

if ! lsb_release -d | grep -q 'CentOS' ; then
  log "This script is for CentOS, you are running: $(lsb_release -d)"
  exit 1
fi

syslog_ng_version="$(rpm -q syslog-ng --qf "%{version}")"
found=$?
if [ "$found" -ne 0 ] ; then
  log "syslog-ng not installed?"
  exit 1
fi

export LOGGLY_USER
export LOGGLY_PASS
export LOGGLY_SUBDOMAIN
export LOGGLY_INPUT_NAME

cat > /tmp/loggly-setup.rb << RUBY
require "rubygems"
require "cgi"
require "json"
require "net/http"
require "socket"
require "uri"

USER = ENV["LOGGLY_USER"]
PASS = ENV["LOGGLY_PASS"]
DOMAIN = ENV["LOGGLY_SUBDOMAIN"]
INPUT_NAME = ENV["LOGGLY_INPUT_NAME"]

def params(hash)
  return nil if hash.nil?
  return hash.collect do |key, val| 
    [CGI.escape(key), CGI.escape(val)].join("=") 
  end.join("&")
end

def call_api(path, options={})
  options[:method] ||= :get
  api_base = "https://#{DOMAIN}.loggly.com/api"
  url = URI.parse("#{api_base}#{path}")
  Net::HTTP.start(url.host) do |http|
    case options[:method]
      when :get
        method = Net::HTTP::Get
        path = [url.path, params(options[:params])].compact.join("?")
        body = nil
      when :post
        method = Net::HTTP::Post
        path = url.path
        body = params(options[:params])
    end # case options[:method]
    STDERR.puts "http request => #{options[:method]} #{path}"
    req = method.new(path)
    req.basic_auth(USER, PASS)
    response = http.request(req, body)
    STDERR.puts response.body
    return JSON.parse(response.body)
  end
end # def call_api

def configure_input
  inputs = call_api("/inputs")
  input = inputs.find { |i| i["name"] == INPUT_NAME }

  if input.nil?
    STDERR.puts "Creating new input: #{INPUT_NAME}"
    result = call_api("/inputs", { 
      :method => :post,
      :params => {
        "name" => INPUT_NAME,
        "description" => "Created by loggly rightscript on #{Socket.gethostname}",
        "service" => "syslogtcp",
      }
    })
    # If we get here, input creation successful.
    STDERR.puts "New input created successfully."
    input = result
  end

  input_id = input["id"]
  add_device_result = call_api("/inputs/#{input_id}/adddevice/", :method => :post)
  STDERR.puts "Added myself to the devices for input '#{INPUT_NAME}' (result: #{add_device_result.inspect})"

  return input
  #input_info = call_api("/inputs/#{input_id}")
end

input = configure_input

if input["port"].nil?
  STDERR.puts "Couldn't find what port to talk to. Something wrong with loggly api?"
  exit 1
end

puts input["port"]
RUBY

port=$(/opt/rightscale/sandbox/bin/ruby /tmp/loggly-setup.rb)
exitcode=$?

if [ "$exitcode" -ne 0 ] ; then
  log "Loggly setup failed."
  exit $exitcode
fi

flagfile="/etc/syslog-ng/loggly-setup-complete"
if [ -f "$flagfile" ] ; then
  log "Loggly setup already occurred, skipping"
  exit 0
fi

log "Setting up syslog-ng to ship logs to logs.loggly.com:$port"

cat >> /etc/syslog-ng/syslog-ng.conf << SYSLOGNG

# Automatically added by $0
destination d_loggly {tcp("logs.loggly.com" port($port));};  
log { source(s_sys); destination(d_loggly); };
# End loggly config
SYSLOGNG

service syslog-ng restart
touch $flagfile
