package Apache::LangURI;

use strict;
use Apache::Constants qw(OK DECLINED DOCUMENT_FOLLOWS 
                         HTTP_MOVED_PERMANENTLY REDIRECT SERVER_ERROR);
use Apache::URI ();
use Apache::Log ();
use Locale::Language qw(code2language);
use Locale::Country  qw(LOCALE_CODE_ALPHA_2 LOCALE_CODE_ALPHA_3 code2country);

use constant DEFAULT_LANG => 'DefaultLanguage';
use constant FORCE_LANG   => 'ForceLanguage';
use constant IGNORE_REGEX => 'IgnorePathRegex';
use constant REDIR_PERM   => 'RedirectPermanent';

our $VERSION = '0.14';

our $A2 = LOCALE_CODE_ALPHA_2;
our $A3 = LOCALE_CODE_ALPHA_3;

our $DEFAULT;

sub handler {
  my $r   = shift;
  my $log = $r->log;

  # maybe some day get this off $ENV{LANG} ?
  $DEFAULT ||= $r->dir_config(DEFAULT_LANG) || 'en';

  if ($r->is_initial_req) {
    for my $ignore ($r->dir_config->get(IGNORE_REGEX)) {
      my $neg = $ignore !~ s/^!// || 0;
      my $rx = eval { qr{$ignore} };
      if ($@) {
        $log->crit("Ignore regex $ignore is invalid: $@");
        return SERVER_ERROR;
      }
      if ($neg == scalar($r->uri =~ $rx)) {
        $log->debug("Ignoring URI which matches regex $ignore");
        return DECLINED;
      }
    }
    # split uri and iterate over each portion

    # acquire hash of from the Accept-Language header
    my %accept;
    if (my $hdr = $r->header_in('Accept-Language')) {
      for (split(/\s*,\s*/, $hdr)) {
        my ($key, @vals) = split /\s*;\s*/;
        $key =~ tr/A-Z_/a-z-/;
        $accept{$key} ||= {};
        unless (@vals) {
          $accept{$key}{q} = 1;
          $log->debug("$key => '1.0'");
        }
        for (@vals) {
          my ($k, $v) = split /\s*=\s*/;
          if ($k =~ /^qs?$/) {
            # some useragents use qs :P
            $v = 1 if ($v eq '');
            $v = 1 if ($v > 1);
            $v = 0 if ($v < 0);
            $accept{$key}{q}  = $v;
            $log->debug("$key => '$v'");
          }
          else {
            $accept{$key}{$k} = $v;
            $log->debug("$key => '$v'");
          }
        }
      }
    }

    # walk the url path looking for language tags.
    # future note: check for actual on-disk entities corresponding to 
    # language tags via subrequests
    
    my @uri = split(/\/+/, $r->uri, -1);
    my ($major, $minor);
    my $i = 1; # segment 0 will be an empty string
    my ($cnt, $pos) = (0, 1);
    while ($i < @uri) {
      if ($uri[$i] =~ /^([A-Za-z]{2})(?:[\-_]([A-Za-z]{2,3}))?$/
          and (code2language($1) and 
            (!$2 || code2country($2,  length($2) == 2 ? $A2 : $A3)))) {
        if (my $subr = $r->lookup_uri(join('/', @uri[0..$i]))) {
          if ($subr->status == DOCUMENT_FOLLOWS and -e $subr->filename) {
            $log->debug(sprintf('Existing path %s', $subr->filename));
            $i++;
            next;
          }
        }
        ($major, $minor) = (lc($1), lc($2));
        $pos = $i; # set the index of the farthest-right language tag
        $cnt++;    # increment the count of discovered tags in the path
        splice(@uri, $i, 1);
      }
      else {
        $i++;
      }
    }

    # adjust Accept-Language header with new data
    my $lang;
    my @order = sort { $accept{$b}{q} <=> $accept{$a}{q} } keys %accept;
    if ($major) {
      $lang = ($minor ? "$major-$minor" : $major);
    }
    else {
      $lang = (@order ? $order[0] : $DEFAULT);
    }
    my $m = $major || substr($lang, 0, 2);
    my $hdr = "$lang;q=1.0";
    $hdr .= ", $m;q=0.8" if $minor;
    for my $k (@order) {
      if ($k =~ /^$m/i) {
        delete $accept{$k};
      }
      else {
        # fucking rad.
        $hdr .= sprintf(', %s;q=%.4f%s', $k, $accept{$k}{q} / 2 , join(';', '', 
          map { "$_=$accept{$k}{$_}" } grep { $_ ne 'q' } keys %{$accept{$k}}));
      }
    }
    $hdr .= ", $DEFAULT;q=0.0001" 
      if (@order and !grep { $_ eq $DEFAULT } @order);

    # modify inbound header for following handlers
    $r->header_in('Accept-Language', $hdr);
    $log->debug("Accept-Language: $hdr");

    # prepare a subrequest that will discover if we are actually pointing
    # to anything
    my $uri  = join('/', @uri);
    if ($r->dir_config(FORCE_LANG) =~ /^(1|true|on|yes)$/) {
      my $subr = $r->lookup_uri($uri || '/');
      if ($subr->status == DOCUMENT_FOLLOWS) {
        my $fn = $subr->filename;
        my $cl = lc($subr->header_out('Content-Language'));
        my $df = lc(substr($DEFAULT, 0, 2));
        my $uri_out;
        
        # if the selected language major can be found in the default language
        # redirect to a path with no rfc3066 segment if the path contains one
        # otherwise leave alone.
        
        if ($df eq $m) {
          return DECLINED if ($cnt == 0); 
          if ($cnt == 1) {
            $log->debug(sprintf("Skipping on default language URI %s", $uri));
            $r->uri($uri);
            return DECLINED;
          }
          push @uri, '' if (-d $fn and (@uri == 1 or $uri[-1] ne ''));
          $uri_out = join('/', @uri) . ($r->args ? '?' . $r->args : '');
          $r->header_out(Location => $uri_out);
          return REDIRECT;
        }
        else {
          # if the subrequest's filename returns a directory on the filesystem,
          # append an empty space so that a trailing slash will be added when
          # the path is reassembled.
          
          if (-d $fn and (@uri == 1 or $uri[-1] ne '')) {
            push @uri, '';
            # even if we had a language segment, we have to redirect or else
            # mod_dir will eat us.
            $cnt = 0;
          }

          # if the selected major cannot be found in the default language
          # append the rfc3066 segment to the path if it does not contain one.
        
          unless ($cnt == 1) {
            splice(@uri, ($cnt ? $pos : -1), 0, $lang);
            $uri_out = join('/', @uri) . ($r->args ? '?' . $r->args : '');
            $r->header_out(Location => $uri_out);
            return $r->dir_config(REDIR_PERM) =~ /^(1|true|on|yes)$/ ? 
              HTTP_MOVED_PERMANENTLY : REDIRECT;
          }
        }
      }
    }
    $r->uri($uri);
  }
  return DECLINED;
}

1;

__END__

=head1 NAME

Apache::LangURI - Rewrite Accept-Language headers from URI path and back

=head1 SYNOPSIS

  # httpd.conf
  
  PerlSetVar DefaultLanguage en

  # for redirecting the url based on the top language 
  # in the inbound header
  PerlSetVar ForceLanguage on

  PerlAddVar IgnorePathRegex ^/foo
  # and the opposite:
  PerlAddVar IgnorePathRegex !^/foo/bar

  PerlTransHandler Apache::LangURI

=head1 DESCRIPTION

Apache::LangURI will attempt to match the first segment of the path
of an http URL to an RFC3066 E<lt>majorE<gt>-E<lt>minorE<gt> language code.
It will also optionally prepend the "best" language code to the path, should
it not already be there. Language tags are normalized to a lower case major
with an upper case minor and a hyphen in between.

=head1 CONFIGURATION


=head3 DefaultLanguage

This defines the default language that will be added at a diminished quality
value after the language found in the URI path, should its major part not
match. This is to ensure that a suitable variant will always be returned when
content negotiation occurs. Defaults to 'en' if omitted.

=head3 ForceLanguage

Setting this variable to a positive (1|true|on|yes) value will cause the
server to redirect the user to a path beginning with the language code of 
the highest quality value found in the Accept-Language header. This occurs 
only when the URI path does not begin with an RFC3066 language code. This
directive can be omitted if this behavior is not desired.

=head3 IgnorePathRegex

Passing a regular expression (optionally prefixed by ! to denote negation)
will limit the effect of this handler to simulate <Location> blocks on a 
transhandler.

=head3 RedirectPermanent

if set to a positive (1|true|on|yes) value, the server will return 301 Moved 
rather than 302 Found on a successful redirection.

=head1 BUGS

Only currently does ISO639 language majors and ISO3166 country minors. No 
support for constructs like "no-sami" or "x-jawa".

RFC3066 includes rules for pairings of ISO639-1/2 and ISO3166 two-character
and three-character denominations. This module does not enforce those rules.

The DefaultLanguage variable will eventually be phased out to use
Apache::Module to derive the value from mod_mime as soon as this author
manages to get it to compile.

Forms that refer to absolute URL paths may no longer function due to the
redirection process, as the POST payload will be interrupted.

=head1 SEE ALSO

Locale::Language
Locale::Country

http://www.ietf.org/rfc3066.txt

ISO 639
ISO 3166

=head1 AUTHOR

Dorian Taylor, E<lt>dorian@foobarsystems.comE<gt>

=head1 COPYRIGHT

Copyright 2003 by Dorian Taylor

=cut
