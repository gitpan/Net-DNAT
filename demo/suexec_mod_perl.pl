#!/usr/bin/perl -w -T

=pod

=head1 EXAMPLE DELIMA

  Example configuration of how to combine the
  security and restrictions of SuExec with the
  power and speed of mod_perl.

  For example, here is the delima:

  There are three webmasters on this unix
  machine:

    billy
    henry
    ralph

  We want hits to billy.com to be run as billy.
  We want hits to henry.com to be run as henry.
  We want hits to ralph.com to be run as ralph.

  They all want to take advantage of mod_perl
  features like PerlHandlers or Apache::Registry
  scripts, but all point to the same IP address:

    10.11.12.13

  All users wish to keep their sources private
  among themselves, so they remove all permissions
  for group and other for their home directories.

  [root@localhost /root]# chmod 0700 /home/*
  [root@localhost /root]# ls -ald /home/*
  drwx------  4 billy  billy  4096 Apr 02 12:00 /home/billy
  drwx------  4 henry  henry  4096 Apr 02 12:00 /home/henry
  drwx------  4 ralph  ralph  4096 Apr 02 12:00 /home/ralph
  [root@localhost /root]#

  Each user is responsible to turn on his own server
  and listen on his own designated port as follows:

    billy.com   =>  8001
    henry.com   =>  8002
    ralph.com   =>  8003

=head1 USER PROCEDURE

  Each user will have his own server and configuration
  files.  In Apache, this is done using the -f option.
  Each configuration file will contain the Port or Listen
  directive with its corresponding port.  Also, mod_perl
  must be enabled to utilize the Apache::DNAT feature.

  [billy@localhost billy]$ tail ~/conf/httpd.conf
  Alias /perl/ /home/billy/www/perl/
  <Location /perl>
    SetHandler perl-script
    PerlHandler Apache::Registry
    Options +ExecCGI
  </Location>
  # Listen: Allows you to bind Apache to specific IP addresses and/or ports
  Listen 8001
  PerlModule Apache::DNAT
  PerlInitHandler Apache::DNAT
  [billy@localhost billy]$ httpd -f ~/conf/httpd.conf
  [billy@localhost billy]$

  (The goes for for the other users, too.)

  No <VirtualHost> sections are required.  No special
  User directive or SuExec configuration is required.

=head1 ADMIN PROCEDURE

  As super user, turn on this DNAT server:

  [root@localhost /root]# suexec_mod_perl.pl

=head1 SEE ALSO

  apache, mod_perl, Net::DNAT, Apache::DNAT

=cut

use strict;
use Net::DNAT;

# Pools definition configuration
my $pools = {
  default => "127.0.0.1:8000",
  billy => "127.0.0.1:8001",
  henry => "127.0.0.1:8002",
  ralph => "127.0.0.1:8003",
};

# Default to some other service for all
# unknown or incomplete requests.
my $default_pool = "default";

my $host_dest = {
  "billy.com"      => "billy",
  "www.billy.com"  => "billy",
  "henry.com"      => "henry",
  "www.henry.com"  => "henry",
  "ralph.com"      => "ralph",
  "www.ralph.com"  => "ralph",
};

run Net::DNAT
  port => 80,
  pools => $pools,
  default_pool => $default_pool,
  host_switch_table => $host_dest,
  user => "nobody",
  ;
