package VoteAnalyze::Admin;
use strict;
use warnings;
use utf8;
use parent qw(VoteAnalyze Amon2::Web);
use File::Spec;

# dispatcher
use VoteAnalyze::Admin::Dispatcher;
sub dispatch {
    return (VoteAnalyze::Admin::Dispatcher->dispatch($_[0]) or die "response is not generated");
}

# setup view
use VoteAnalyze::Admin::View;
{
    sub create_view {
        my $view = VoteAnalyze::Admin::View->make_instance(__PACKAGE__);
        no warnings 'redefine';
        *VoteAnalyze::Admin::create_view = sub { $view }; # Class cache.
        $view
    }
}

# load plugins
__PACKAGE__->load_plugins(
    'Web::FillInFormLite',
    '+VoteAnalyze::Admin::Plugin::Session',
);

sub show_error {
    my ( $c, $msg, $code ) = @_;
    my $res = $c->render( 'error.tx', { message => $msg } );
    $res->code( $code || 500 );
    return $res;
}

# for your security
__PACKAGE__->add_trigger(
    AFTER_DISPATCH => sub {
        my ( $c, $res ) = @_;

        # http://blogs.msdn.com/b/ie/archive/2008/07/02/ie8-security-part-v-comprehensive-protection.aspx
        $res->header( 'X-Content-Type-Options' => 'nosniff' );

        # http://blog.mozilla.com/security/2010/09/08/x-frame-options/
        $res->header( 'X-Frame-Options' => 'DENY' );

        # Cache control.
        $res->header( 'Cache-Control' => 'private' );
    },
);

1;
