#!/bin/sh
# This script will work for Ubuntu 10.04
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

# At some point this script is so silly we should just use puppet or chef. -Jordan

progname=$(basename $0)
log() {
  logger -st $progname "$@"
}

package_version() {
  dpkg-query -W --showformat '${Version}' "$@"
}

package_install() {
  pkg=$1
  if ! package_version $pkg > /dev/null 2>&1 ; then
    apt-get install -y $pkg
    if [ $? -ne 0 ] ; then
      log "Failed installing $pkg ?"
      exit 1
    fi
  fi
}

if ! lsb_release -d | grep -q 'Ubuntu' ; then
  log "This script is for Ubuntu, you are running: $(lsb_release -d)"
  exit 1
fi

export LOGGLY_USER
export LOGGLY_PASS
export LOGGLY_SUBDOMAIN
export LOGGLY_INPUT_NAME

internal_ip="$(ip addr show dev eth0 | awk '/inet / { print $2 }' | sed -e 's,/.*,,')"

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

  # Add ourselves to the API in using the whatever IP we hit the API with
  add_device_result = call_api("/inputs/#{input_id}/adddevice/", :method => :post)
  STDERR.puts "Added myself to the devices for input '#{INPUT_NAME}' (result: #{add_device_result.inspect})"

  # In case we're on EC2 and in the same location, add our local IP address just in case.
  add_device_internal_result = call_api("/devices", :method => :post, :params => {
    "input_id" => input_id.to_s,
    "ip" => "$internal_ip", # comes from 'ip addr show eth0, etc'
  }) # call_api
  STDERR.puts "Added myself ($internal_ip) to the devices for input '#{INPUT_NAME}' (result: #{add_device_internal_result.inspect})"

  return input
end # def configure_input

input = configure_input
STDERR.puts({ :input => input }.inspect)

if input["port"].nil?
  STDERR.puts "Couldn't find what port to talk to. Something wrong with loggly api?"
  exit 1
end

puts input["port"]
RUBY

# Don't try to use rightscale's ruby sandbox, this will let us
# use, more generally, any CentOS 5 system.
#port=$(/opt/rightscale/sandbox/bin/ruby /tmp/loggly-setup.rb)

config="/etc/rsyslog.d/99-loggly-shipper.conf"
if [ -f "$config" ] ; then
  log "Loggly setup already occurred, skipping"
  exit 0
fi

package_install rsyslog
package_install ruby
package_install libjson-ruby

# Configure the input and get the port to log to
port=$(ruby /tmp/loggly-setup.rb)
exitcode=$?

if [ "$exitcode" -ne 0 ] ; then
  log "Loggly setup failed."
  exit $exitcode
fi

log "Setting up rsyslog to ship logs to ec2.logs.loggly.com:$port"
cat >> $config << RSYSLOG
*.* @@ec2.logs.loggly.com:$port
RSYSLOG

log "Reloading config for rsyslog"
restart rsyslog

log "Successfully configured rsyslog to ship logs to Loggly :)"
