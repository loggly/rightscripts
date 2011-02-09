#!/bin/sh
# DO NOT USE THIS SCRIPT
# It uses APIs that are not yet documented and are not yet finalized.
# Also, it is incomplete because I wam waiting for such public-documentation.

if ! lsb_release -d | grep -q 'CentOS' ; then
  echo "This script is for CentOS, you are running: $(lsb_release -d)"
  exit 1
fi

syslog_ng_version="$(rpm -q syslog-ng --qf "%{version}")"
found=$?
if [ "$found" -ne 0 ] ; then
  echo "syslog-ng not installed?"
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
    puts "#{options[:method]} #{path}"
    req = method.new(path)
    req.basic_auth(USER, PASS)
    response = http.request(req, body)
    puts response.body
    return JSON.parse(response.body)
  end
end # def call_api

def configure_input
  inputs = call_api("/inputs")
  input = inputs.find { |i| i["name"] == INPUT_NAME }

  if input.nil?
    puts "Creating new input: #{INPUT_NAME}"
    result = call_api("/inputs", { 
      :method => :post,
      :params => {
        "name" => INPUT_NAME,
        "description" => "Created by loggly rightscript on #{Socket.gethostname}",
        "service" => "syslogtcp",
      }
    })
    # If we get here, input creation successful.
    puts "New input created successfully."
    input = result
  end

  input_id = input["id"]
  add_device_result = call_api("/inputs/#{input_id}/adddevice/", :method => :post)
  puts "Added myself to the devices for input '#{INPUT_NAME}' (result: #{add_device_result.inspect})"

  return input
  #input_info = call_api("/inputs/#{input_id}")
end

input = configure_input
# input["port"] contains the port we should log to
# TODO(sissel): configure syslog-ng
RUBY

exec /opt/rightscale/sandbox/bin/ruby /tmp/loggly-setup.rb

