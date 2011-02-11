#!/bin/sh
# This script will work for CentOS 5.4
#
# How to use:
#   On RightScale, add this as a RightScript.
#   Else, run the script passing the variables below in on the environment:
#     LOGGLY_USER=youruser LOGGLY_PASS=yourpass ... sh log-to-loggly.sh
#
# TODO(sissel): see if we can just make this a ruby script, not shell calling ruby.

# We have to list these here otherwise RightScale's script won't detect 
# these variables as being inputs.
# $LOGGLY_USER  - the username to access loggly with
# $LOGGLY_PASS  - the password for the username above
# $LOGGLY_SUBDOMAIN - your loggly subdomain name (foo.loggly.com, just 'foo')
# $LOGGLY_INPUT_NAME - the name of the input

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

# Don't try to use rightscale's ruby sandbox, this will let us
# use, more generally, any CentOS 5 system.
#port=$(/opt/rightscale/sandbox/bin/ruby /tmp/loggly-setup.rb)

if ! rpm -q syslog-ng > /dev/null 2>&1 ; then
  yum install -y syslog-ng
  if [ $? -ne 0 ] ; then
    log "Failed installing syslog-ng?"
    exit 1
  fi
fi

# Install ruby if not present
if ! which ruby > /dev/null 2>&1 ; then
  yum install -y ruby
  if [ $? -ne 0 ] ; then
    log "Failed installing ruby?"
    exit 1
  fi
fi

# Install ruby-json if not present
if ! rpm -q ruby-json > /dev/null 2>&1 ; then
  yum install -y ruby-json
  if [ $? -ne 0 ] ; then
    log "Failed installing ruby-json?"
    exit 1
  fi
fi

# Configure the input and get the port to log to
port=$(ruby /tmp/loggly-setup.rb)
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

log "Setting up syslog-ng to ship logs to ec2.logs.loggly.com:$port"
cat >> /etc/syslog-ng/syslog-ng.conf << SYSLOGNG

# Automatically added by $0
destination d_loggly {tcp("ec2.logs.loggly.com" port($port));};  
log { source(s_sys); destination(d_loggly); };
# End loggly config
SYSLOGNG

log "Restarting syslog-ng"
service syslog-ng restart

log "Successfully configured syslog-ng to ship logs to Loggly :)"
touch $flagfile
