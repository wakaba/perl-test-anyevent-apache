use strict;
use warnings;
use Path::Class;
use lib file(__FILE__)->dir->parent->subdir('t_deps', 'lib')->stringify;
use lib glob file(__FILE__)->dir->parent->subdir('t_deps', 'modules', '*', 'lib')->stringify;
use lib file(__FILE__)->dir->parent->subdir('lib')->stringify;
use Test::X1;
use Test::More;
use Test::AnyEvent::Apache;
use Web::UserAgent::Functions qw(http_get);

my $RootD = file(__FILE__)->dir->parent->absolute->resolve;

test {
    my $c = shift;

    my $server = Test::AnyEvent::Apache->new;
    $server->get_app_config(sub {
        my $server = shift;
        my $port = $server->port;
        return qq{
            DocumentRoot $RootD/t
        };
    });
    my $cv1 = AE::cv;
    $server->start_apache_as_cv->cb(sub {
        my $started = $_[0]->recv or die "Can't start apache";
        my $host = 'localhost:' . $server->port;
        http_get
            url => qq<http://$host/test-anyevent-apache.t>,
            anyevent => 1,
            cb => sub {
                my (undef, $res) = @_;
                test {
                    is $res->code, 200;
                    like $res->content, qr{Hoge Fuga Abc};
                    $cv1->send;
                } $c;
            };
    });
    $cv1->cb(sub {
        $server->stop_apache_as_cv->cb(sub {
            test {
                done $c;
                undef $c;
            } $c;
        });
    });
} n => 2, name => 'basic';

run_tests;
