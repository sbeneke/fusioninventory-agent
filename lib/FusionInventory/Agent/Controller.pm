package FusionInventory::Agent::Controller;

use strict;
use warnings;

use English qw(-no_match_vars);

use FusionInventory::Agent::Logger;


my $count = 0;

sub new {
    my ($class, %params) = @_;

    die 'no url parameter'        unless $params{url};

    my $self = {
        logger       => $params{logger} ||
                        FusionInventory::Agent::Logger->create(),
        maxDelay     => $params{maxDelay} || 3600,
        initialDelay => $params{delaytime},
        url          => _getCanonicalURL($params{url}),
        id           => 'server' . $count++,
    };
    bless $self, $class;

    $self->{nextRunDate} = $self->_computeNextRunDate()
        if !$self->{nextRunDate};

    $self->{logger}->debug(
        "[target $self->{id}] Next server contact planned for " .
        localtime($self->{nextRunDate})
    );

    return $self;
}

sub _getCanonicalURL {
    my ($string) = @_;

    my $url = URI->new($string);

    my $scheme = $url->scheme();
    if (!$scheme) {
        # this is likely a bare hostname
        # as parsing relies on scheme, host and path have to be set explicitely
        $url->scheme('http');
        $url->host($string);
        $url->path('ocsinventory');
    } else {
        die "invalid protocol for URL: $string"
            if $scheme ne 'http' && $scheme ne 'https';
        # complete path if needed
        $url->path('ocsinventory') if !$url->path();
    }

    return $url;
}

sub getUrl {
    my ($self) = @_;

    return $self->{url};
}

sub setNextRunDate {
    my ($self, $nextRunDate) = @_;

    lock($self->{nextRunDate}) if $self->{shared};
    $self->{nextRunDate} = $nextRunDate;
}

sub resetNextRunDate {
    my ($self) = @_;

    lock($self->{nextRunDate}) if $self->{shared};
    $self->{nextRunDate} = $self->_computeNextRunDate();
}

sub getNextRunDate {
    my ($self) = @_;

    return $self->{nextRunDate};
}

sub getFormatedNextRunDate {
    my ($self) = @_;

    return $self->{nextRunDate} > 1 ?
        scalar localtime($self->{nextRunDate}) : "now";
}

sub getMaxDelay {
    my ($self) = @_;

    return $self->{maxDelay};
}

sub setMaxDelay {
    my ($self, $maxDelay) = @_;

    $self->{maxDelay} = $maxDelay;
}

# compute a run date, as current date and a random delay
# between maxDelay / 2 and maxDelay
sub _computeNextRunDate {
    my ($self) = @_;

    my $ret;
    if ($self->{initialDelay}) {
        $ret = time + ($self->{initialDelay} / 2) + int rand($self->{initialDelay} / 2);
        $self->{initialDelay} = undef;
    } else {
        $ret =
            time                   +
            $self->{maxDelay} / 2  +
            int rand($self->{maxDelay} / 2);
    }

    return $ret;
}

1;
__END__

=head1 NAME

FusionInventory::Agent::Controller - Control server

=head1 DESCRIPTION

This is the control server for the agent.

=head1 METHODS

=head2 new(%params)

The constructor. The following parameters are allowed, as keys of the %params
hash:

=over

=item I<logger>

the logger object to use

=item I<maxDelay>

the maximum delay before contacting the target, in seconds
(default: 3600)

=item I<url>

the server URL (mandatory)

=back

=head2 getUrl()

Return the server URL for this target.

=head2 getNextRunDate()

Get nextRunDate attribute.

=head2 getFormatedNextRunDate()

Get nextRunDate attribute as a formated string.

=head2 setNextRunDate($nextRunDate)

Set next execution date.

=head2 resetNextRunDate()

Set next execution date to a random value.

=head2 getMaxDelay($maxDelay)

Get maxDelay attribute.

=head2 setMaxDelay($maxDelay)

Set maxDelay attribute.
