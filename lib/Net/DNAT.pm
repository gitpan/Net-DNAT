package Net::DNAT;

use strict;

use Exporter;

use vars qw(@ISA $VERSION $listen_port);
use Net::Server::Multiplex;
use IO::Socket;

# Just pull the VERSION from the light Apache::DNAT module
$VERSION = do {require Apache::DNAT; $Apache::DNAT::VERSION;};
@ISA = qw(Net::Server::Multiplex);

$listen_port = getservbyname("http", "tcp");
# DEBUG warnings
use Carp qw(cluck);
$SIG{__WARN__} = \&Carp::cluck;

sub _resolve_it {
  my $string = shift;
  my @result = ();
  my $port = $listen_port;
  if ($string =~ s/:(\d+)//) {
    $port = $1;
  } elsif ($string =~ s/:(\w+)//) {
    $port = getservbyname($1, "tcp");
  }
  if ($string !~ /^\d+\.\d+\.\d+\.\d+$/) {
    my $j;
    ($j, $j, $j, $j, @result) = gethostbyname($string);
    die "Failed to resolve [$string] to an IP address\n"
      unless @result;
    map { $_ = join(".", unpack("C4", $_)); } @result;
  } else {
    @result = ($string);
  }
  map { $_ .= ":$port"; } @result;
  return @result;
}

sub post_configure_hook {
  my $self = shift;
  my $conf_hash = {
    @{ $self->{server}->{configure_args} }
  };
  my $old_pools_ref = $conf_hash->{pools} ||
    die "The 'pools' setting is missing!\n";
  my $new_pools_ref = {};
  foreach my $poolname (keys %{ $old_pools_ref }) {
    # The first element is the cycle index
    my @list = (0);
    my $dest = $old_pools_ref->{$poolname};
    if (!ref $dest) {
      push(@list, _resolve_it($dest));
    } elsif (ref $dest eq "ARRAY") {
      foreach my $i (@{ $dest }) {
        push(@list, _resolve_it($i));
      }
    } else {
      die "Unimplemented type of pool destination [".(ref $dest)."]\n";
    }
    $new_pools_ref->{$poolname} = [ @list ];
  }
  $self->{pools} = $new_pools_ref;

  my $old_switch_table_ref = $conf_hash->{host_switch_table} || {};
  my $new_switch_table_ref = {};
  foreach my $old_host (keys %{ $old_switch_table_ref }) {
    my $new_host = $old_host;
    if ($new_host =~ s/^([a-z\-\.]*[a-z])\.?$/\L$1/i) {
      $new_switch_table_ref->{$new_host} = $old_switch_table_ref->{$old_host};
    } else {
      die "Invalid hostname [$old_host] in host_switch_table\n";
    }
  }
  $self->{host_switch_table} = $new_switch_table_ref;

  $self->{switch_filters} = $conf_hash->{switch_filters} || [];
  # Run a quick sanity check on each pool destination
  for (my $i = scalar $#{ $self->{switch_filters} };
       $i > 0; $i-=2) {
    if (!$self->{pools}->{$self->{switch_filters}->[$i]}) {
      die "No such 'switch_filters' pool [".($self->{switch_filters}->[$i])."]\n";
    }
  }

  $self->{default_pool} = $conf_hash->{default_pool} || undef;
  if (!defined $self->{default_pool}) {
    die "The 'default_pool' setting nust be specified!\n";
  }
  if (!$self->{pools}->{$self->{default_pool}}) {
    die "The 'default_pool' [$self->{default_pool}] has not been defined!\n";
  }
  $self->{connect_timeout} =
    defined $conf_hash->{connect_timeout} ?
      $conf_hash->{connect_timeout} :
        30;
}

sub mux_connection {
  my $self = shift;
  shift; # I do not need mux
  my $fh   = shift;
  print STDERR "DEBUG: Connection on fileno [".fileno($fh)."]\n";
  $self->{state} = "REQUEST";
  # Store tied file handle within object
  $self->{fh} = $fh;
  # Grab peer information before it's gone
  $self->{peeraddr} = $self->{net_server}->{server}->{peeraddr};
  $self->{peerport} = $self->{net_server}->{server}->{peerport};
}


sub mux_input {
  my $self = shift;
  my $mux  = shift;
  my $fh   = shift;
  my $data = shift;
  my $state = $self->{state};
  if ($state eq "REQUEST") {
    print STDERR "DEBUG: input on [REQUEST] ($$data)\n";
    if ($$data =~ s%^([^\r\n]*)\r?\n%%) {
      # First newline reached.
      my $request = $1;
      if ($request =~ m%
          (\w+)\s+        # method
          (/.*)\s+        # path
          HTTP/(1\.[01])  # protocol
          $%ix) {
        $self->{request_method}  = $1;  # GET or POST
        $self->{request_path}    = $2;  # URL path
        $self->{request_proto}   = $3;  # 1.0 or 1.1
        $self->{state} = $state = "HEADERS";
      } else {
        $$data = "";
        $mux->write($fh, "Request Format Not recognized!\n");
        $mux->shutdown($fh, 2);
      }
    }
  }

  if ($state eq "HEADERS" && $$data) {
    print STDERR "DEBUG: input on [HEADERS] ($$data)\n";
    # Search for the "nothing" line
    if ($$data =~ s/^((.*\n)*)\r?\n//) {
      # Found! Jump to next state.
      $self->{request_headers_block} = $1;
      # Wipe some headers for cleaner protocol
      # conversion and for security reasons.
      $self->{request_headers_block} =~
        s%^(Connection|
            Keep-Alive|
            Remote-Addr|
            Remote-Port|
            ):.*\n
              %%gmix;

      # Add headers for Apache::DNAT
      $self->{request_headers_block} .=
        "Remote-Addr: $self->{peeraddr}\n".
          "Remote-Port: $self->{peerport}\n";

      $self->{state} = $state = "CONTENT";
      # Determine correct pool destination
      # based on the request $_
      $_ = "$self->{request_method} $self->{request_path} HTTP/1.0\r\n$self->{request_headers_block}";
      # Rectify host header for simplicity
      s/^Host:\s*([\w\.]*\w)\.?((:\d+)?)\r?\n/Host: \L$1$2\r\n/im;

      my $pool = undef;

      # First run through the switch_filters
      my @switch_filters = @{ $self->{net_server}->{switch_filters} };
      while (@switch_filters) {
        my ($ref, $then_pool) = splice(@switch_filters, 0, 2);
        if (my $how = ref $ref) {
          if ($how eq "CODE") {
            if (&$ref()) {
              $pool = $then_pool;
              last;
            }
          } elsif ($how eq "Regexp") {
            if ($_ =~ $ref) {
              $pool = $then_pool;
              last;
            }
          } else {
            die "Switch filter to [$then_pool] smells too weird!\n";
          }
        } else {
          die "Switch filter [$ref] is not a ref!\n";
        }
      }

      # Then run through the host_switch_table
      if (!defined($pool) && m%^Host: ([\w\.]+)%m) {
        my $request_host = $1;

        foreach my $host (keys %{ $self->{net_server}->{host_switch_table} }) {
          if ( $request_host eq $host ) {
            $pool = $self->{net_server}->{host_switch_table}->{$host};
            last;
          }
        }
      }

      # Otherwise, just use the default
      if (!defined($pool)) {
        $pool = $self->{net_server}->{default_pool};
      }

      print STDERR "DEBUG: POOL DETERMINED: [$pool]\n";
      my $pool_ref = $self->{net_server}->{pools}->{$pool};
      # Increment cycle counter.
      # If it exceeds pool size
      if (++($pool_ref->[0]) > $#{ $pool_ref }) {
        # Start over with 1 again.
        $pool_ref->[0] = 1;
      }
      print STDERR "DEBUG: POOL CYCLE INDEX [$pool_ref->[0]]\n";
      my $peeraddr = $pool_ref->[$pool_ref->[0]];
      print STDERR "DEBUG: Connecting to destination [$peeraddr]\n";

      $@ = "";
      my $peersock = eval {
        local $SIG{ALRM} = sub { die "Timed out!\n"; };
        alarm ($self->{net_server}->{connect_timeout});
        new IO::Socket::INET $peeraddr or die "$!\n";
      };
      alarm(0); # Reset alarm
      $peersock = undef if $@;
      if ($peersock) {
        print STDERR "DEBUG: Connected successfully with fileno [".fileno($peersock)."]\n";
        $mux->add($peersock);
        my $proxy_object = bless {
          state => "CONTENT",
          fh => $peersock,
          proto => $self->{request_proto},
          complement_object => $self,
          net_server => $self->{net_server},
        }, (ref $self);
        print STDERR "DEBUG: Complement for socket on fileno [".fileno($fh)."] created on fileno [".fileno($peersock)."]\n";
        $self->{complement_object} = $proxy_object;
        $mux->set_callback_object($proxy_object, $peersock);
        $mux->write($peersock, "$_\r\n");
        #$_ = "$self->{request_method} $self->{request_path} HTTP/1.0\r\n$self->{request_headers_block}";
      } else {
        print STDERR "DEBUG: Could not connect to [$peeraddr]: $@";
        $mux->write($fh, "ERROR: Pool [$pool] Index [$pool_ref->[0]] (Peer $peeraddr) is down: $@\n");
        $$data = "";
        $mux->shutdown($fh, 2);
      }
    }
  }

  if ($state eq "CONTENT" && $$data) {
    print STDERR "DEBUG: input on [CONTENT] on fileno [".fileno($fh)."] (".(length $$data)." bytes) to socket on fileno [".fileno($self->{complement_object}->{fh})."]\n";
    $mux->write($self->{complement_object}->{fh}, $$data);
    $$data = "";
  }

}

sub mux_eof {
  my $self = shift;
  my $mux  = shift;
  my $fh   = shift;
  my $data = shift;
  print STDERR "DEBUG: EOF received on fileno [".fileno($fh)."] ($$data)\n";

  # If it hasn't been consumed by now,
  # then too bad, wipe it anyways.
  $$data = "";
  if ($self->{complement_object}) {
    print STDERR "DEBUG: Shutting down complement on fileno [".fileno($self->{complement_object}->{fh})."]\n";
    # If this end was closed, then tell the
    # complement socket to close.
    $mux->shutdown($self->{complement_object}->{fh}, 2);
    # Make sure that when the complement
    # socket finishes via mux_eof, that
    # it doesn't waste its time trying
    # to shutdown my socket, because I'm
    # already finished.
    delete $self->{complement_object}->{complement_object};
  }
}


1;
__END__

=head1 NAME

Net::DNAT - Psuedo Layer7 Packet Processer

=head1 SYNOPSIS

  use Net::DNAT;

  run Net::DNAT <settings...>;

=head1 DESCRIPTION

This module is intended to be used for testing
applications designed for load balancing systems.
It listens on specified ports and forwards the
incoming connections to the appropriate remote
applications.  The remote application can be
on a separate machine or on the same machine
listening on a different port and/or address.

=head1 PEER SOCKET SPOOF

This implementation does not actually translate
the destination address in the packet headers
and resend the packet, like true DNAT does.
It is implemented like a port forwarding proxy.
When a client connects, a new socket is made to
the remote application and the connection is
tunnelled to/from the client.  This causes the
peer side of the socket to appear to the remote
application like it is coming from the Net::DNAT
box instead of the real client.  This peer
modification side effect is usually fine for
testing and developmental purposes, though.

=head1 HTTP

If you do not care about where the hits on your
web server are coming from, then you do not need
to worry about this section.  If the remote
application is the Apache 1.3.x web server,
( see http://httpd.apache.org/ ), then the
Apache::DNAT module can be used to correctly
and seemlessly UnDNATify this peer munging
described above.  If mod_perl is enabled for
Apache, then add this line to its httpd.conf:

  PerlModule Apache::DNAT
  PerlInitHandler Apache::DNAT

If you cannot do this, (because it is a web server
other than Apache, or you do not have mod_perl
enabled, or you do not have access to the web
server, or you just do not want the CPU overhead
to fix the peer back to normal, or for whatever
reason), then it will still function fine.  Just
the server logs will be inaccurate and the CGI
programs will run with the wrong environment
variables pertaining to the peer (i.e.,
REMOTE_ADDR and REMOTE_PORT).

=head1 EXAMPLE CONFIGURATION


HARDWARE:


  \  |     |  /
   \_|_____|_/
   /         \
  |           |
  | INTERNET  |
  |           |
   \_________/
        |
        |
  ======|========= Firewall ================
        |
   _____|_____ Public Interface  (x.x.x.x)
  |           |
  | Net::DNAT |
  |___________|
     |         Private Interface (10.0.0.1)
     |
     |   _________________________
     \__| Apache::DNAT (10.0.0.2) |
     |  |_________________________|
     |
     |   _________________________
  H  \__| Apache::DNAT (10.0.0.3) |
  U  |  |_________________________|
  B  |
     |   _________________________
     \__| Apache::DNAT (10.0.0.4) |
     |  |_________________________|
     |
     |   _________________________
     \__| Apache::DNAT (10.0.0.5) |
        |_________________________|


SOFTWARE:


  #!/usr/bin/perl
  # Program: dnat.pl
  # Run this at startup on the box with both
  # the public and the private interfaces.

  use strict;
  use Net::DNAT;

  my $pools = {
    main => [ "10.0.0.2", "10.0.0.3" ],
    banner => "10.0.0.4",
    devel =>  "10.0.0.5:8080",
  };

  my $site2pool = {
    "site.com"     => "main",
    "www.site.com" => "main",
    "banner.site.com" => "banner",
    "dev.site.com" => "devel",
  };

  run Net::DNAT
    port => 80,
    pools => $pools,
    default_pool => "main",
    host_switch_table => $site2pool,
    ;


=head1 EXAMPLES

See demo/* from the distribution for some more examples.

=head1 TODO

  Support for HTTP/1.1 protocol conversion to 1.0 protocol and back again.
  Support for SSL protocol conversion to plain text.
  Support for html error pages for internal errors:
    1) Server outage
    2) Protocol misconformities
  Support for error logs.
  Support for access logs.
  Support for HTTP/1.1 KeepAlive timeout and KeepAliveRequests.
  Support for CVS protocol.
  Support for FTP protocol.
  Support for DNS protocol.
  Support for periodic service checks (Net::Ping)
    to disable and enable forwarding.

=head1 LAYER

  More information on network layers:

  http://uwsg.iu.edu/usail/network/nfs/network_layers.html

=head1 COPYRIGHT

  Copyright (C) 2002,
  Rob Brown, rob@roobik.com

  This package may be distributed under the same terms as Perl itself.

  All rights reserved.

=head1 SEE ALSO

 L<Apache::DNAT>,
 L<Net::Server>,
 L<IO::Multiplex>

=cut
