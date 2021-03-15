package Graphs;

use Mojo::Base 'Mojolicious', -signatures;
use Data::Dumper;
use YAML::Syck 'LoadFile';
use Text::CSV qw( csv );
use Math::BigInt;
use Mojo::File 'path';
use Data::Dumper;
use lib 'lib';
use Mojolicious::Plugin::TagHelpers ;
use Mojolicious::Validator;
use Mojolicious::Validator::Validation;
my $lib;
BEGIN {
    my $gitdir = Mojo::File->curfile;
    my @cats = @$gitdir;
    while (my $cd = pop @cats) {
        if ($cd eq 'git') {
            $gitdir = path(@cats,'git');
            last;
        }
    }
    $lib =  $gitdir->child('utilities-perl','lib')->to_string; #return utilities-perl/lib
};
use lib $lib;
use SH::UseLib;
use Model::GetCommonConfig;

=head1 NAME

Graphs

=head1 SYNOPSIS

    use Mojolicious::Commands;
    use lib 'lib';
    $ENV{GRAPH_CONFIG_FILE}= 't/etc/my-graph.yml'
    # Start command line interface for application
    Mojolicious::Commands->start_app('Graphs');

=head1 DESCRIPTION

Startup script for running daemon for a graph.

=head1 METHODS

=head2 startup

Called by parent.

=cut



# Answer to /
sub startup ($self) {
    $self->plugin('TagHelpers');
    my $mydat;

    # Everything can be customized with options
    die "Missing GRAPH_CONFIG_FILE" if ! $ENV{GRAPH_CONFIG_FILE};
    my $config = $self->plugin(Config => {file => $ENV{GRAPH_CONFIG_FILE}});
	$self->mode('development');
	my $gcc = Model::GetCommonConfig->new->get_mojoapp_config($0);
	$config->{$_} = $gcc->{$_} for (keys %$gcc);
    $self->config($config);
    $self->secrets($gcc->{secrets});


    my $datfile = $config->{datafile};
    for ($datfile) {
        if ( /ml$/) {
            $YAML::Syck::ImplicitTyping=1;
            $mydat = LoadFile($datfile);
        } elsif (/csv$/) {
#                warn "$datfile is read";
            $mydat = csv (in => $datfile, sep_char=>";" );    # as array of array ref
        } else {
            die "Unknown filetype $_";
        }
    }

    #handle dates
    my $date_c = Mojo::Date->with_roles('+Extended');

    say Dumper $mydat;
    my $series;
    for my $r(@$mydat) {
        my $nr=[0,0];
        for my $i (0 .. $#$r) {
            if ($r->[$i] =~ /\d-\d/) {
                # DD/MM-YY
                $nr->[$i] = int($date_c->from_short_date($r->[$i])->epoch1000);
                say "shortdate: ".$nr->[$i];
            }
            elsif ($r->[$i] =~ /^\d+:\d+$/) {
                $nr->[$i] = $date_c->from_time_interval($r->[$i])->epoch1000;
            }
            elsif($r->[$i]=~/^\d{9,10}$/) {
                $nr->[$i] = $r->[$i] * 1000;
            }
            elsif($r->[$i] =~ /\d\:\d/) {
                $nr->[$i] = $date_c->from_time_interval($r->[$i])->epoch1000 ; # Fake seconds
            }
            else {
                $nr->[$i] = $r->[$i];
                say "Unknown";
            }
        }
        push @$series,$nr;
    }
    @$series = sort {$a->[0] <=> $b->[0]} @$series;
#    say Dumper $y;

    my $r = $self->routes;

    $r->get( '/' => sub {
        my $c = shift;

        $Data::Dumper::Terse = 1;        # don't output names where feasible
        $Data::Dumper::Indent = 0;       # turn off all pretty print
        my $mydata= Dumper $series;
        $mydata=~ s/\'(\d+(.\d+)?)\'/$1/g;
        say STDERR $mydata;
        my $config = $c->config;

        # set default values
        if (exists $config->{input}) {
            while (my ($k,$v) = each %{ $config->{input} }) {
                if ($v->{type} eq 'shortdate') {
                    my @localtime = localtime;
                    $v->{value} = sprintf ("%d/%d-%d",$localtime[3], $localtime[4]+1,$localtime[5] -100);
                }
                elsif ($v->{type} eq 'timesec') {
                    $v->{value} = $date_c->new($series->[$#$series]->[1]/1000)->timesec;
                }
                else {
                    #last y value
                    $v->{value} = $series->[$#$series]->[1];
                }
            }
        }
        $c->stash($config);

        $c->stash(mydata=>$mydata);
        $c->render(template => 'live', format => 'html');
    });
    $r->namespaces(['Graphs']);
    # /datapoint?x=12%2F02-16&y=7%3A40
    $r->get('/datapoint' => sub {
        my $c = shift;
        my $x_in= $c->param('x')//die "No x";
        my $y_in= $c->param('y')//die "No y";

        my $validator = Mojolicious::Validator->new;
        my $v = Mojolicious::Validator::Validation->new(validator => $validator);
        $v->input( {x => $x_in, y => $y_in} );
        $v->required('x')->check('like',qr/^\d\d?\/\d\d?\-\d\d$/);
        $v->required('y')->check('like',qr/^\d\d?:\d\d$/);
        if ($v->is_valid('x') && $v->is_valid('y')) {
            my $x = $v->param('x');
            my $y = $v->param('y');
             my $config = $c->config;
            open (my $fh,'>>',$c->config->{datafile});
            print $fh "'$x';'$y'\n";
            close $fh;
            $config->{input}->{x}->{value}= $x;
            $config->{input}->{y}->{value}= $y;

            push @$series, [$date_c->from_short_date($x)->epoch1000,$date_c->from_time_interval($y)->epoch1000];
            @$series  = sort {$a->[0] <=> $b->[0] } @$series;

            $c->stash($config);
        } else {
            my $err='';
            for my $k(qw/x y/) {
                if($v->has_error($k)) {
                    $err .= "$k: ". $v->error($k);
                }
            }
            $c->stash('msg' => sprintf("Invalid values. $err"));
        }

        # Print data
        @$series = sort {$a->[0] <=> $b->[0]} @$series;
        $Data::Dumper::Terse = 1;        # don't output names where feasible
        $Data::Dumper::Indent = 0;       # turn off all pretty print
        my $mydata= Dumper $series;
        $mydata=~ s/\'(\d+(.\d+)?)\'/$1/g;
        say $mydata;
        $c->stash($config);
        $c->stash(mydata=>$mydata);
        $c->render(template => 'live', format=> 'html');

    });
}

1;


