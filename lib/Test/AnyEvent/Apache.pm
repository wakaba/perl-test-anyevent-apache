package Test::AnyEvent::Apache;
use strict;
use warnings;
use AnyEvent;
use AnyEvent::Util;
use Path::Class;
use File::Temp;

our $DEBUG ||= $ENV{TEST_APACHE_DEBUG};

our $HTTPDPath;

our $FoundHTTPDPath;
our $FoundAPXSPath;
sub search_httpd () {
    return if $FoundHTTPDPath and -x $FoundHTTPDPath;
    for (
        $ENV{TEST_APACHE_HTTPD},
        $HTTPDPath,
        'local/apache/httpd-2.4/bin/httpd',
        'local/apache/httpd-2.2/bin/httpd',
        'local/apache/httpd-2.0/bin/httpd',
        '/usr/sbin/apache2',
        '/usr/sbin/httpd',
        '/usr/sbin/httpd',
        '/usr/local/sbin/httpd',
        '/usr/local/apache/bin/httpd',
    ) {
        next unless defined $_;
        if (-x $_) {
            $FoundHTTPDPath = file($_)->absolute->resolve->stringify;
            warn "Found Apache httpd: $FoundHTTPDPath" if $DEBUG;
            last;
        }
    }

    my $apxs_expected = $FoundHTTPDPath;
    $apxs_expected =~ s{/(?:httpd|apache2)$}{/apxs};
    for (
        $ENV{TEST_APACHE_APXS},
        $apxs_expected,
    ) {
        next unless defined $_;
        if (-x $_) {
            $FoundAPXSPath = file($_)->absolute->resolve->stringify;
            last;
        }
    }
}

sub available {
    search_httpd;
    return $FoundHTTPDPath && -x $FoundHTTPDPath;
}

sub new {
    return bless {}, $_[0];
}

sub server_root_temp {
    return $_[0]->{server_root_temp} = File::Temp->newdir('Test-Apache-XX'.'XX'.'XX', TMPDIR => 1, CLEANUP => !$DEBUG);
}

sub server_root_d {
    return $_[0]->{server_root_d} ||= dir($_[0]->server_root_temp)->absolute->resolve;
}

sub server_root_dir_name {
    my $self = shift;
    return $self->{server_root_dir_name} ||= tempdir('TEST-APACHE-XX'.'XX'.'XX', TMPDIR => 1, CLEANUP => !$DEBUG);
}

sub pid_f {
    my $self = shift;
    return $self->{pid_f} ||= $self->server_root_d->file('apache.pid');
}

sub builtin_modules_as_cv {
    my $self = shift;
    my $cv = AE::cv;
    if ($self->{builtin_modules}) {
        $cv->send($self->{builtin_modules});
    } else {
        my $result;
        $self->run_httpd_as_cv(['-l'], onstdout => \$result)->cb(sub {
            if ($_[0]->recv) {
                $cv->send($self->{builtin_modules} = {map { s/^\s+//; s/\s+$//; $_ => 1 } grep { /^ / } split /\n/, $result});
            } else {
                $cv->send($self->{builtin_modules} = {});
            }
        });
    }
    return $cv;
}

sub dso_path_as_cv {
    my $self = shift;
    my $cv = AE::cv;
    if ($self->{dso_path}) {
        $cv->send($self->{dso_path});
    } else {
        search_httpd;
        if ($FoundAPXSPath) {
            my $path;
            (run_cmd [$FoundAPXSPath, '-q', 'LIBEXECDIR'], '>' => \$path)->cb(sub {
                chomp $path;
                $cv->send($self->{dso_path} = $path);
            });
        } else {
            $cv->send($self->{dso_path} = 'modules');
        }
    }
    return $cv;
}

sub port_as_cv {
    my $self = shift;
    my $cv = AE::cv;
    if ($self->{port}) {
        $cv->send($self->{port});
    } else {
        # XXX blocking
        require Test::AnyEvent::Apache::Net::TCP::FindPort;
        $cv->send($self->{port} = Test::AnyEvent::Apache::Net::TCP::FindPort->find_listenable_port);
    }
    return $cv;
}

sub port {
    return $_[0]->{port};
}

sub conf_f {
    my $self = shift;
    return $self->{conf_f} ||= $self->server_root_d->file('apache.conf');
}

sub get_app_config {
    if (@_ > 1) {
        $_[0]->{get_app_config} = $_[1];
    }
    return $_[0]->{get_app_config} || sub { '' };
}

sub require_module {
    $_[0]->{required_modules}->{$_[1]} = 1;
}

sub generate_conf_as_cv {
    my $self = shift;
    my $cv = AE::cv;
    if ($self->{conf_generated}) {
        $cv->send;
        return $cv;
    }
    
    $self->server_root_d->subdir('logs')->mkpath;
    # XXX blocking
    $self->server_root_d->file('logs', 'startup_log')->openw;
    $self->server_root_d->file('logs', 'access_log')->openw;
    $self->server_root_d->file('logs', 'error_log')->openw;

    my $pid_f = $self->pid_f;

    my $cv1 = AE::cv;
    $cv1->begin;
    $cv1->begin;
    my $modules;
    $self->builtin_modules_as_cv->cb(sub {
        $modules = $_[0]->recv;
        $cv1->end;
    });
    $cv1->begin;
    my $port;
    $self->port_as_cv->cb(sub {
        $port = $_[0]->recv;
        $cv1->end;
    });
    $cv1->begin;
    my $dso_path;
    $self->dso_path_as_cv->cb(sub {
        $dso_path = $_[0]->recv;
        $cv1->end;
    });
    $cv1->end;

    # XXX blocking
    my $mime_types_f = $self->server_root_d->file('mime.types');
    print { $mime_types_f->openw } q{
text/plain txt
text/html html
text/css css
text/javascript js
image/gif gif
image/png png
image/jpeg jpeg jpg
image/vnd.microsoft.icon ico
    };

    $cv1->cb(sub {
        my $app_config = $self->get_app_config->($self); # need $self->port
        my $conf_file_name = $self->conf_f->stringify;
        # XXX blocking
        open my $conf_f, '>', $conf_file_name or die "$0: $conf_file_name: $!";
        $self->{required_modules}->{log_config} = 1;
        $self->{required_modules}->{mime} = 1;
        for (keys %{$self->{required_modules}}) {
            printf $conf_f "LoadModule %s_module $dso_path/mod_%s.so\n", $_, $_
                unless $modules->{"mod_$_.c"};
        }
        
        print $conf_f qq{
            ServerName test
            Listen $port
            ServerRoot @{[$self->server_root_d]}
            TypesConfig $mime_types_f
            PidFile $pid_f
            LockFile @{[$self->server_root_d]}/accept.lock
            CustomLog logs/access_log "%v\t%h %l %u %t %r %>s %b"
            LogLevel debug
        };
        print $conf_f $app_config;
        close $conf_f;
        $cv->send;
    });
    $self->{conf_generated} = 1;
    return $cv;
}

sub run_httpd_as_cv {
    my ($self, $args, %opt) = @_;
    my $cv = AE::cv;
    search_httpd;
    my $result;
    if ($DEBUG) {
        warn '$ ' . join(' ', $FoundHTTPDPath, @$args) . "\n";
    }
    (
        run_cmd
            [$FoundHTTPDPath, @$args],
            '>' => $opt{onstdout} || sub {
                warn "HTTPD(o): $_[0]" if defined $_[0];
            },
            '2>' => $opt{onstderr} || sub {
                warn "HTTPD(e): $_[0]" if defined $_[0];
            },
    )->cb(sub {
        my $result = $_[0]->recv;
        if ($result == -1) {
            warn "$0: $FoundHTTPDPath: $!\n";
            $cv->send(0);
        } elsif ($result & 127) {
            warn "$0: $FoundHTTPDPath: " . ($result & 127) . "\n";
            $cv->send(0);
        } elsif ($result >> 8 != 0) {
            warn "$0: $FoundHTTPDPath: Exit with status " . ($result >> 8) . "\n";
            $cv->send(0);
        } else {
            $cv->send(1);
        }
    });
    return $cv;
}

sub start_apache_as_cv {
    my $self = shift;
    my $cv = AE::cv;
    $self->generate_conf_as_cv->cb(sub {
        my $conf_f = $self->conf_f;
        my $root_d = $self->server_root_d;
        my $pid_f = $self->pid_f;
        $self->tail_as_cv;
        warn "Starting apache with $conf_f...\n" if $DEBUG;
        $self->run_httpd_as_cv(
            ['-f' => $conf_f->stringify, '-k' => 'start', '-E', $self->server_root_d->file('logs', 'startup_log')->stringify],
        )->cb(sub {
            if ($_[0]->recv) {
                warn "Waiting for starting apache process ($root_d)...\n" if $DEBUG;
                my $i = 0;
                my $timer; $timer = AE::timer 0, 0.010, sub {
                    if (-f $pid_f) {
                        undef $timer;
                        $cv->send(1);
                    }
                    if ($i++ >= 60_00) {
                        warn "$0: $FoundHTTPDPath: Apache does not start in 60 seconds";
                        undef $timer;
                        $cv->send(0);
                    }
                };
            } else {
                $cv->send(0);
            }
        });
    });
    return $cv;
}

sub stop_apache_as_cv {
    my $self = shift;
    my $cv = AE::cv;
    my $cv1 = AE::cv;
    my $conf_f = $self->conf_f;
    my $i = 0;
    my $pid_f = $self->pid_f;
    my $root_d = $self->server_root_d;
    my $timer; $timer = AE::timer 0, 10, sub {
        $self->run_httpd_as_cv(
            ['-f' => $conf_f, '-k' => 'stop'],
        )->cb(sub {
            if ($_[0]->recv) {
                warn "Waiting for stopping apache process ($root_d)...\n" if $DEBUG;
                my $j = 0;
                my $w; $w = AE::timer 0, 0.0010, sub {
                    unless (-f $pid_f) {
                        undef $w;
                        undef $timer;
                        $cv1->send(1);
                    }
                    if ($j++ >= 10_00) {
                        undef $w;
                        warn "$0: $FoundHTTPDPath: Apache does not end in 10 seconds\n";
                    }
                };
            } else {
                if ($i++ > 5) {
                    warn "$0: $FoundHTTPDPath: Cannot stop apache\n";
                    undef $timer;
                    $cv1->send(0);
                }
            }
        });
    };
    $cv1->cb(sub {
        kill 'TERM', $self->{tail_pid} if $self->{tail_pid};
        $cv->send($_[0]->recv);
    });
    return $cv;
}

sub tail_as_cv {
    my $self = shift;
    my $cv = AE::cv;
    if ($self->{tail_pid}) {
        $cv->send;
        return $cv;
    }
    my $logs_f = $self->server_root_d->file('logs', '*_log');
    (run_cmd
        ['tail', '-f', glob $logs_f],
        '$$' => \($self->{tail_pid}),
        '>' => sub {
            return unless defined $_[0];
            my $s = 'Log: ' . $_[0];
            $s =~ s/\n/\nLog: /g;
            $s .= "\n" unless $s =~ s/\n$//;
            print STDERR $s;
        },
    )->cb(sub {
        delete $self->{tail_pid};
        $cv->send;
    });
    return $cv;
}

sub DESTROY {
    my $self = shift;
    if (-f $self->pid_f) {
        my $cv = $self->stop_apache_as_cv;
        eval { $cv->recv };
    }

    {
        local $@;
        eval { die };
        if ($@ =~ /during global destruction/) {
            warn "Detected (possibly) memory leak";
        }
    }
}

1;
