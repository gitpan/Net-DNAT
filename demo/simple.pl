#!/usr/bin/perl -w -T

# Simple Port Redirecting Configuration
use strict;
use Net::DNAT;

# Forward incoming connections on the privileged
# low port 80 to an unprivleged high port 8000
run Net::DNAT
  port => 80,
  pools => { safe => "127.0.0.1:8000" },
  default_pool => "safe",
  user => "nobody",
  group => "nobody",
  ;

# This is great for security because the entire
# web server can run and even start as an
# unprivileged user on a high port.
#
# This is also helpful for development and testing
# because you don't have to be root to restart
# the web server, yet you still get to use
# "pretty" URLs, i.e.:
#
#   http://box/cgi-bin/test.cgi
#
# instead of the uglier:
#
#   http://localhost:8080/cgi-bin/test.cgi
#
# so development appears closer to what production
# would look like.
