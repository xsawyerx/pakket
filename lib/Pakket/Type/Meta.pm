package Pakket::Type::Meta;

# ABSTRACT: An object representing a pakket Metadata

use v5.22;
use Moose;
use MooseX::StrictConstructor;
use MooseX::Clone;
use namespace::autoclean;

# core
use Carp;
use List::Util qw(any none);
use experimental qw(declared_refs refaliasing signatures);

# non core
use YAML ();

# local
use Pakket::Constants qw(PAKKET_PACKAGE_SPEC);
use Pakket::Utils qw(clean_hash get_application_version);

has [qw(prereqs scaffold build test)] => (
    'is'  => 'ro',
    'isa' => 'Maybe[HashRef]',
);

has [qw(path)] => (
    'is'  => 'ro',
    'isa' => 'Maybe[Path::Tiny]',
);

with qw(
    MooseX::Clone
);

sub BUILD ($self, @) {
    return;
}

sub as_hash ($self) {
    my $result = {
        $self->%{qw(prereqs scaffold build test)},
        'version' => get_application_version(),
    };
    return clean_hash($result);
}

sub prereqs_v2 ($self) {
    my $prereqs_v3 = $self->prereqs // {};
    my %prereqs_v2;
    foreach my $phase (keys $prereqs_v3->%*) {
        next if none {$_ eq $phase} qw(build configure runtime);
        foreach my $type (keys $prereqs_v3->{$phase}->%*) {
            next if none {$_ eq $type} qw(requires);
            foreach my $short_name (keys $prereqs_v3->{$phase}{$type}->%*) {
                my ($category, $name) = split (m{[/]}xms, $short_name);
                $prereqs_v2{$category}{$phase}{$name}{'version'} = $prereqs_v3->{$phase}{$type}{$short_name};
            }
        }
    }
    return clean_hash(\%prereqs_v2);
}

sub new_from_prereqs ($class, $input, %additional) {
    return $class->new(
        'prereqs' => $input,
        %additional,
    );
}

sub new_from_metafile ($class, $path, %additional) {
    my $input = YAML::Load($path->slurp_utf8);
    return $class->new_from_metadata($input, %additional, 'path' => $path->absolute);
}

sub new_from_metadata ($class, $input, %additional) {
    my $params = _try_meta_v3($input) // _try_meta_v2($input);
    delete $params->{'version'};
    return $class->new($params->%*, %additional);

    #ref $meta{'source'} eq 'ARRAY'
    #and $meta{'source'} = join ('', $meta{'source'}->@*);
}

sub new_from_specdata ($class, $input, %additional) {
    my $params = clean_hash(_try_spec_v3($input) // _try_spec_v2($input) // _try_spec_metafile($input) // {});
    delete $params->{'version'};
    return $class->new($params->%*, %additional);
}

# private

sub _try_spec_v3 ($spec) {
    exists $spec->{'Pakket'} && $spec->{'Pakket'}{'version'} && $spec->{'Pakket'}{'version'} >= 3
        and return $spec->{'Pakket'};
    return;
}

sub _try_spec_v2 ($spec) {
    if (exists $spec->{'Prereqs'} || exists $spec->{'build_opts'}) {
        my %build;
        if (my $build_opts = $spec->{'build_opts'}) {
            $build{'environment'}       = $build_opts->{'env_vars'};
            $build{'configure-options'} = $build_opts->{'configure_flags'};
            $build{'make-options'}      = $build_opts->{'build_flags'};
            my @pre = (
                $build_opts->{'pre-build'} ? $build_opts->{'pre-build'}->@* : (),
                $build_opts->{'pre_build'} ? $build_opts->{'pre_build'}->@* : (),
            );
            my @post = (
                $build_opts->{'post-build'} ? $build_opts->{'post-build'}->@* : (),
                $build_opts->{'post_build'} ? $build_opts->{'post_build'}->@* : (),
            );
            @pre
                and $build{'pre'} = \@pre;
            @post
                and $build{'post'} = \@post;
            $build{'no-test'} = $spec->{'skip'}{'test'};
        }
        return {
            'prereqs' => _convert_spec_v2_prereqs($spec->{'Prereqs'}) || {},
            'build'   => \%build,
        };
    }
    return;
}

sub _try_spec_metafile ($spec) {
    exists $spec->{'Meta'}
        and return $spec->{'Meta'}->%*;
    return;
}

sub _convert_spec_v2_prereqs ($prereqs) {
    $prereqs
        or return {};

    my \%prereqs = $prereqs;

    my %result;
    foreach my $category (keys %prereqs) {
        foreach my $phase (keys $prereqs{$category}->%*) {
            foreach my $name (keys $prereqs{$category}{$phase}->%*) {
                $result{$phase}{'requires'}{"$category/$name"} = $prereqs{$category}{$phase}{$name}{'version'};
            }
        }
    }
    return \%result;
}

sub _try_meta_v3 ($data) {
    exists $data->{'Pakket'}
        and return $data->{'Pakket'};

    return;
}

sub _try_meta_v2 ($meta) {
    return clean_hash({
            'prereqs'  => _convert_meta_v2_prereqs($meta),
            'scaffold' => _convert_meta_v2_scaffold($meta),
            'build'    => _convert_meta_v2_build($meta),
        },
    );
}

sub _convert_meta_v2_prereqs ($meta) {
    my $requires = $meta->{'requires'};
    my %result;
    foreach my $type (keys $requires->%*) {
        foreach my $dep ($requires->{$type}->@*) {
            if ($dep !~ PAKKET_PACKAGE_SPEC()) {
                croak('Cannot parse requirement: ', $dep);
            } else {
                $result{$type}{'requires'}{"$1/$2"} = $3 // 0;
            }
        }
    }
    return \%result;
}

sub _convert_meta_v2_scaffold ($meta) {
    my \%meta = $meta;
    my %skip = %{$meta{'skip'} // {}};
    delete @skip{qw(test)};
    my %result = (
        (%meta{'patch'}) x !!$meta{'patch'},
        ('environment' => $meta{'manage'}{'env'}) x !!$meta{'manage'}{'env'},
        ('pre'         => $meta{'pre-manage'}) x !!$meta{'pre-manage'},
        ('post'        => $meta{'post-manage'}) x !!$meta{'post-manage'},
        ('skip'        => \%skip) x !!%skip,
    );
    return \%result;
}

sub _convert_meta_v2_build ($meta) {
    my \%meta   = $meta;
    my $no_test = $meta{'skip'}{'test'};
    my %result  = (
        ('environment' => $meta{'build'}{'env'}) x !!$meta{'build'}{'env'},
        ('pre'               => $meta{'pre-build'}) x !!$meta{'pre-build'},
        ('post'              => $meta{'post-build'}) x !!$meta{'post-build'},
        ('configure-options' => $meta{'build'}{'configure-options'}) x !!$meta{'build'}{'configure-options'},
        ('make-options'      => $meta{'build'}{'make-options'}) x !!$meta{'build'}{'make-options'},
        ('no-test'           => $no_test) x !!defined $no_test,
    );
    return \%result;
}

#sub _convert_requires ($meta) {
#my %result;
#my $requires = $meta->{'requires'};
#foreach my $type (keys %{$requires}) {
#foreach my $dep (@{$requires->{$type}}) {
#if ($dep !~ PAKKET_PACKAGE_SPEC()) {
#croak('Cannot parse requirement: ', $dep);
#} else {
#$result{$1}{$type}{$2} = {'version' => $3 // 0};
#}
#}
#}
#return \%result;
#}

#sub _convert_build_options ($meta_spec) {
#my $opts = $meta_spec->{'build'}
#or return;
#
#my %result;
#$result{'env_vars'}        = $opts->{'env'}               if $opts->{'env'};
#$result{'configure_flags'} = $opts->{'configure-options'} if $opts->{'configure-options'};
#$result{'build_flags'}     = $opts->{'make-options'}      if $opts->{'make-options'};
#$result{'pre-build'}       = $meta_spec->{'pre-build'}    if $meta_spec->{'pre-build'};
#$result{'post-build'}      = $meta_spec->{'post-build'}   if $meta_spec->{'post-build'};
#
#return \%result;
#}

__PACKAGE__->meta->make_immutable;

1;

__END__