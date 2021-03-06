package OAuth::Lite2::Client::ClientCredentials;

use strict;
use warnings;

use base 'Class::ErrorHandler';

use Params::Validate qw(HASHREF);
use Carp ();
use Try::Tiny;
use URI;
use LWP::UserAgent;
use HTTP::Request;
use MIME::Base64 qw(encode_base64);

use OAuth::Lite2;
use OAuth::Lite2::Util qw(build_content);
use OAuth::Lite2::Formatters;
use OAuth::Lite2::Client::TokenResponseParser;

=head1 NAME

OAuth::Lite2::Client::ClientCredentials - OAuth 2.0 ClientCredentials Profile Client

=head1 SYNOPSIS

    my $client = OAuth::Lite2::Client::WebServer->new(
        id               => q{my_client_id},
        secret           => q{my_client_secret},
        access_token_uri => q{http://example.org/token},
    );

    sub get_access_token {
        my $your_app = shift;

        my $access_token = $client->get_access_token(
            scope => q{photo}, 
        ) or return $your_app->error( $client->errstr );

        $your_app->store->save( access_token  => $access_token->access_token  );
        $your_app->store->save( expires_at    => time() + $access_token->expires_in    );
        $your_app->store->save( refresh_token => $access_token->refresh_token );
    }

    sub refresh_access_token {
        my $your_app = shift;

        my $access_token = $client->refresh_access_token(
            refresh_token => $refresh_token,
        ) or return $your_app->error( $client->errstr );

        $your_app->store->save( access_token  => $access_token->access_token  );
        $your_app->store->save( expires_at    => time() + $access_token->expires_in    );
        $your_app->store->save( refresh_token => $access_token->refresh_token );
    }

    sub access_to_protected_resource {
        my $your_app = shift;

        my $access_token  = $your_app->store->get("access_token");
        my $expires_at    = $your_app->store->get("expires_at");
        my $refresh_token = $your_app->store->get("refresh_token");

        unless ($access_token) {
            $your_app->show_reauthorize_page();
            return;
        }

        if ($expires_at < time()) {
            $your_app->refresh_access_token();
            return;
        }

        my $req = HTTP::Request->new( GET => q{http://example.org/photo} );
        $req->header( Authorization => sprintf(q{OAuth %s}, $access_token) );
        my $agent = LWP::UserAgent->new;
        my $res = $agent->request($req);
        ...
    }


=head1 DESCRIPTION

OAuth 2.0 ClientCredentials Profile Client.


=head2 new( %params )

=over 4

=item id

Client ID

=item secret

Client secret

=item access_token_uri

token endpoint uri on auth-server.

=item refresh_token_uri

refresh-token endpoint uri on auth-server.
if you omit this, access_token_uri is used instead.

=item agent

user agent. if you omit this, LWP::UserAgent's object is set by default.
You can use your custom agent or preset-agents.

See also

L<OAuth::Lite2::Agent::Dump>
L<OAuth::Lite2::Agent::Strict>
L<OAuth::Lite2::Agent::PSGIMock>

=back

=cut

sub new {
    my $class = shift;

    my %args = Params::Validate::validate(@_, {
        id                => 1,
        secret            => 1,
        # format          => { optional => 1 },
        access_token_uri  => { optional => 1 },
        refresh_token_uri => { optional => 1 },
        agent             => { optional => 1 },
    });

    my $self = bless {
        id                => undef,
        secret            => undef,
        access_token_uri  => undef,
        refresh_token_uri => undef,
        last_request      => undef,
        last_response     => undef,
        %args,
    }, $class;

    unless ($self->{agent}) {
        $self->{agent} = LWP::UserAgent->new;
        $self->{agent}->agent(
            join "/", __PACKAGE__, $OAuth::Lite2::VERSION);
    }

    # $self->{format} ||= 'json';
    $self->{response_parser} = OAuth::Lite2::Client::TokenResponseParser->new;

    return $self;
}

=head2 get_access_token( %params )

=over 4

=item scope

=back

=cut

sub get_access_token {
    my $self = shift;

    my %args = Params::Validate::validate(@_, {
        scope        => { optional => 1 },
        uri          => { optional => 1 },
        use_basic_schema    => { optional => 1 },
        # secret_type => { optional => 1 },
        # format      => { optional => 1 },
    });

    unless (exists $args{uri}) {
        $args{uri} = $self->{access_token_uri}
            || Carp::croak "uri not found";
    }

    # $args{format} ||= $self->{format};

    my %params = (
        grant_type    => 'client_credentials',
        # format      => $args{format},
    );

    unless ($args{use_basic_schema}){
        $params{client_id}      = $self->{id};
        $params{client_secret}  = $self->{secret};
    }

    $params{scope} = $args{scope}
        if $args{scope};

    # $params{secret_type} = $args{secret_type}
    #     if $args{secret_type};

    my $content = build_content(\%params);
    my $headers = HTTP::Headers->new;
    $headers->header("Content-Type" => q{application/x-www-form-urlencoded});
    $headers->header("Content-Length" => bytes::length($content));
    $headers->header("Authorization" => sprintf(q{Basic %s}, encode_base64($self->{id}.":".$self->{secret},''))) 
        if($args{use_basic_schema});
    my $req = HTTP::Request->new( POST => $args{uri}, $headers, $content );

    my $res = $self->{agent}->request($req);
    $self->{last_request}  = $req;
    $self->{last_response} = $res;

    my ($token, $errmsg);
    try {
        $token = $self->{response_parser}->parse($res);
    } catch {
        $errmsg = "$_";
    };
    return $token || $self->error($errmsg);

}

=head2 refresh_access_token( %params )

=over 4

=item refresh_token

=back

=cut

sub refresh_access_token {
    my $self = shift;

    my %args = Params::Validate::validate(@_, {
        refresh_token => 1,
        uri           => { optional => 1 },
        use_basic_schema    => { optional => 1 },
        # secret_type => { optional => 1 },
        # format      => { optional => 1 },
    });

    unless (exists $args{uri}) {
        $args{uri} = $self->{access_token_uri}
            || Carp::croak "uri not found";
    }

    # $args{format} ||= $self->{format};

    my %params = (
        grant_type    => 'refresh_token',
        refresh_token => $args{refresh_token},
        # format        => $args{format},
    );

    unless ($args{use_basic_schema}){
        $params{client_id}      = $self->{id};
        $params{client_secret}  = $self->{secret};
    }

    # $params{secret_type} = $args{secret_type}
    #     if $args{secret_type};

    my $content = build_content(\%params);
    my $headers = HTTP::Headers->new;
    $headers->header("Content-Type" => q{application/x-www-form-urlencoded});
    $headers->header("Content-Length" => bytes::length($content));
    $headers->header("Authorization" => sprintf(q{Basic %s}, encode_base64($self->{id}.":".$self->{secret},''))) 
        if($args{use_basic_schema});
    my $req = HTTP::Request->new( POST => $args{uri}, $headers, $content );

    my $res = $self->{agent}->request($req);
    $self->{last_request}  = $req;
    $self->{last_response} = $res;

    my ($token, $errmsg);
    try {
        $token = $self->{response_parser}->parse($res);
    } catch {
        $errmsg = "$_";
    };
    return $token || $self->error($errmsg);
}

=head2 last_request

Returns a HTTP::Request object that is used
when you obtain or refresh access token last time internally.

=head2 last_request

Returns a HTTP::Response object that is used
when you obtain or refresh access token last time internally.

=cut

sub last_request  { $_[0]->{last_request}  }
sub last_response { $_[0]->{last_response} }

=head1 AUTHOR

Lyo Kato, E<lt>lyo.kato@gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Lyo Kato

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut

1;
