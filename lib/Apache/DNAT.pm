package Apache::DNAT;

use strict;
use Apache::Constants qw(DECLINED);
use Socket qw(sockaddr_in inet_aton inet_ntoa);

sub handler {
  my $r = shift;
  my $c = $r->connection;
  my $old_remote_addr = $c->remote_addr;
  my ($old_port, $old_addr) = sockaddr_in($old_remote_addr);
  $old_addr = inet_ntoa $old_addr;
  if ($old_addr =~ /^(127|10|192.168|172\.(1[6-9]|2\d|3[01]))\./) {
    # Martian IP so it is safe
    my $headers = $r->headers_in;
    my $new_addr = $headers->{"remote-addr"};
    my $new_port = $headers->{"remote-port"};
    if ($new_addr && $new_port) {
      delete $headers->{"remote-addr"};
      delete $headers->{"remote-port"};
      $c->remote_addr(scalar sockaddr_in($new_port, inet_aton($new_addr)));
      $c->remote_ip($new_addr);
    }
  }

  # Now pretend like I didn't do anything.
  return DECLINED;
}

1;
__END__

=head1 NAME

Apache::DNAT - mod_perl Apache module to undo the side-effects of Net::DNAT

=head1 SYNOPSIS

  # in httpd.conf

  PerlModule Apache::DNAT
  PerlInitHandler Apache::DNAT

=head1 DESCRIPTION

This module is only intended to be used in conjuction with
Net::DNAT and the Apache web server.  Net::DNAT may alter
the source port and IP address of web requests.  This module
will correct it back to its original settings for more
accurate REMOTE_ADDR and REMOTE_PORT environment for CGIs
and for logging.

=head1 COPYRIGHT

  Copyright (C) 2002,
  Rob Brown, rob@roobik.com

  This package may be distributed under the same terms as Perl itself.

  All rights reserved.

=head1 SEE ALSO

 L<Net::DNAT>,
 L<mod_perl>,

=cut
