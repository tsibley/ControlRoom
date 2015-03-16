#!/usr/bin/env perl
use 5.018;
use warnings;
use utf8;
use open qw< :std :encoding(UTF-8) >;

package ControlRoom {
    use Web::Simple;

    use FindBin qw< $Bin >;
    use Module::Runtime qw< require_module >;
    use Types::Standard qw< :types >;
    use Path::Tiny 0.053;
    use HTTP::Status qw< :constants >;
    use YAML::Tiny;
    use Try::Tiny;
    use JSON::MaybeXS;
    use Plack::App::File;
    use List::MoreUtils qw< all >;

    use namespace::clean;
    use experimental qw< postderef >;

    has console_dir => (
        is      => 'ro',
        isa     => InstanceOf['Path::Tiny'],
        coerce  => sub { ref $_[0] ? $_[0] : path($_[0]) },
        default => sub { path($Bin)->child("console/") },
    );

    has console_app => (
        is  => 'lazy',
        isa => CodeRef,
    );

    sub _build_console_app {
        my $self = shift;
        return Plack::App::File->new(root => $self->console_dir)->to_app;
    }

    has config_dir => (
        is      => 'ro',
        isa     => InstanceOf['Path::Tiny'],
        coerce  => sub { ref $_[0] ? $_[0] : path($_[0]) },
        default => sub { path($Bin)->child("pipelines/") },
    );

    has pipelines => (
        is  => 'lazy',
        isa => ArrayRef[ConsumerOf['ControlRoom::Pipeline']],
    );

    sub _build_pipelines {
        my $self = shift;
        my @pipelines =
             map { $self->new_pipelines_from_file($_) }
            grep { $_->is_file }
                 $self->config_dir->children(qr/\.ya?ml$/i);

        my %names;
        $names{$_->name}++ for @pipelines;
        die "More than one pipeline with the same name"
            if grep { $_ > 1 } values %names;

        return \@pipelines;
    }

    sub pipeline {
        my $self = shift;
        my $name = shift;
        state $known = {
            map {; $_->name => $_ } $self->pipelines->@*
        };
        return $known->{$name};
    }

    sub new_pipelines_from_file {
        my $self   = shift;
        my $file   = shift or die "No file given";
        return map { $self->new_pipeline($_) }
            YAML::Tiny->read($file)->@*;
    }

    sub new_pipeline {
        my $self   = shift;
        my $config = shift
            or die "No pipeline config given";

        my $runner = $self->new_runner(delete $config->{runner});

        return ControlRoom::Pipeline->new(
            %$config,
            runner => $runner,
        );
    }

    sub new_runner {
        my $self   = shift;
        my $config = shift || {};
        my $name = delete $config->{name}
            or die "No runner name specified";
        my $class = "ControlRoom::Runner::\u$name";
        require_module($class);
        return $class->new(%$config);
    }

    sub json {
        my $self = shift;
        my $data = shift;
        return [
            HTTP_OK,
            [ 'Content-Type' => 'application/json; charset=utf-8' ],
            [ encode_json($data) ],
        ];
    }

    sub dispatch_request {
        'GET + /pipelines' => sub {
            my ($self) = @_;
            return $self->json([
                map { $_->name } $self->pipelines->@*
            ]);
        },
        '/pipeline/*...' => sub {
            my ($self, $name) = @_;
            $name =~ s/\+/ /g;

            my $pipeline = $self->pipeline($name)
                or return [ HTTP_NOT_FOUND, [], [] ];

            return (
                'GET + ~' => sub {
                    $self->json($pipeline->as_hash);
                },
                'POST + /run + %@targets=' => sub {
                    my $targets = $_[1];

                    return [ HTTP_BAD_REQUEST, [], [] ]
                        unless all { $pipeline->known_target($_) } @$targets;

                    my %result = (
                        stdout  => undef,
                        stderr  => undef,
                        success => undef,
                        message => undef,
                        started => time,
                        ended   => undef,
                    );

                    try {
                        ($result{stdout}, $result{stderr}) = $pipeline->run_targets(@$targets);
                        $result{success} = \1;
                    } catch {
                        $result{message} = "$_";
                        $result{success} = \0;
                    };
                    $result{ended} = time;
                    return $self->json(\%result);
                },
            );
        },
        '/'           => sub { [ HTTP_TEMPORARY_REDIRECT, [ Location => '/console/' ], [] ] },
        '/console...' => sub { redispatch_to '/static/index.html' },
        '/static...'  => sub { shift->console_app },
    }
}

package ControlRoom::Pipeline {
    use Moo;
    use Types::Standard qw< :types >;
    use namespace::clean;

    has name => (
        required => 1,
        is       => 'ro',
        isa      => Str,
    );

    has description => (
        is  => 'ro',
        isa => Str,
    );

    has runner => (
        required => 1,
        is       => 'ro',
        isa      => ConsumerOf['ControlRoom::Runner'],
        handles  => [qw[ targets run_targets known_target ]],
    );

    sub as_hash {
        my $self = shift;
        return {
            name        => $self->name,
            description => $self->description,
            runner      => $self->runner->as_hash,
            targets     => $self->targets,
        };
    }
}

package ControlRoom::Runner {
    use Moo::Role;
    use Types::Standard qw< :types >;
    use namespace::clean;

    has targets => (
        required => 1,
        is       => 'lazy',
        isa      => ArrayRef[Str],
    );

    has name => (
        is  => 'lazy',
        isa => Str,
    );

    requires '_build_targets';
    requires 'run_targets';

    sub _build_name {
        my $self = shift;
        return ref($self) =~ s/^ControlRoom::Runner:://r;
    }
}

package ControlRoom::Runner::Make {
    use Moo;
    use Types::Standard qw< :types >;
    use Path::Tiny 0.053;
    use List::Util 1.29 qw< pairmap >;
    use Capture::Tiny qw< capture >;
    use Log::Contextual::Easy::Default;
    use namespace::clean;

    use experimental qw< postderef >;

    with 'ControlRoom::Runner';

    has dir => (
        required => 1,
        is       => 'ro',
        isa      => InstanceOf['Path::Tiny'],
        coerce   => sub { ref $_[0] ? $_[0] : path($_[0]) },
    );

    has args => (
        is      => 'ro',
        isa     => ArrayRef[Str],
        default => sub { [] },
    );

    has vars => (
        is      => 'ro',
        isa     => Map[Str,Str],
        default => sub { {} },
    );

    has targets_cmd => (
        is        => 'ro',
        isa       => Str,
        predicate => 1,
    );

    sub _build_targets {
        my $self = shift;
        die "Either targets or targets_cmd is required in the config"
            unless $self->has_targets_cmd;
        my ($stdout, $stderr) = $self->capture_system( $self->targets_cmd );
        return [ split /\n/, $stdout ];
    }

    sub known_target {
        my $self   = shift;
        my $target = shift;
        state $known = {
            map {; $_ => 1 } $self->targets->@*
        };
        return $known->{$target};
    }

    sub run_targets {
        my $self    = shift;
        my @targets = @_;
        my @make = (
            "make",
            $self->args->@*,
            "-C" => $self->dir->stringify,
            @targets,
            $self->vars_as_string || ()
        );
        return $self->capture_system(@make);
    }

    sub vars_as_string {
        my $self = shift;
        return join " ", pairmap { "$a=$b" } $self->vars->%*;
    }

    sub capture_system {
        my $self = shift;
        my @cmd  = @_;
        Dlog_debug { "running command: $_" } @cmd;

        return capture {
            use autodie ':all';
            system(@cmd);
        };
    }

    sub as_hash {
        my $self = shift;
        return {
            name => $self->name,
            dir  => $self->dir->stringify,
        }
    }
}

ControlRoom->run_if_script;
