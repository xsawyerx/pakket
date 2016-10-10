package Pakket::Installer;

# ABSTRACT: Install pakket packages into an installation directory

use JSON::MaybeXS         qw< decode_json >;
use Moose;
use Path::Tiny            qw< path  >;
use Types::Path::Tiny     qw< Path  >;
use File::Copy::Recursive qw< dircopy >;
use File::Basename        qw< basename >;
use Time::HiRes           qw< time >;
use Log::Any              qw< $log >;
use Pakket::Log;
use Pakket::Utils         qw< is_writeable >;
use Pakket::Version::Requirements;
use Pakket::Constants qw<PARCEL_METADATA_FILE PARCEL_FILES_DIR>;

use namespace::autoclean;

with 'Pakket::Role::RunCommand';

# Sample structure:
# ~/.pakket/
#        bin/
#        etc/
#        repos/
#        libraries/
#                  active ->
#

has 'pakket_dir' => (
    'is'       => 'ro',
    'isa'      => Path,
    'coerce'   => 1,
    'required' => 1,
);

has 'parcel_dir' => (
    'is'       => 'ro',
    'isa'      => Path,
    'coerce'   => 1,
    'required' => 1,
);

has 'keep_copies' => (
    'is'      => 'ro',
    'isa'     => 'Int',
    'default' => sub {1},
);

has 'index_file' => (
    'is'       => 'ro',
    'isa'      => Path,
    'coerce'   => 1,
    'required' => 1,
);

has 'index' => (
    'is'       => 'ro',
    'isa'      => 'HashRef',
    'lazy'     => 1,
    'builder'  => '_build_index',
    'required' => 1,
);

sub _build_index {
    my $self = shift;

    return decode_json $self->index_file->slurp_utf8;
}

# TODO:
# this should be implemented using a fetcher class
# because it might be from HTTP/FTP/Git/Custom/etc.
sub fetch_package;

sub install {
    my ( $self, @packages ) = @_;

    if ( !@packages ) {
        $log->notice('Did not receive any parcels to deliver');
        return;
    }

    my $pakket_dir = $self->pakket_dir;

    $pakket_dir->is_dir
        or $pakket_dir->mkpath();

    my $work_dir = $pakket_dir->child( time() );

    if ( $work_dir->exists ) {
        $log->error(
            "Internal installation directory exists ($work_dir), exiting",
        );

        exit 1;
    }

    $work_dir->mkpath();

    my $active_link = $pakket_dir->child('active');

    # we copy any previous installation
    if ( $active_link->exists ) {
        my $orig_work_dir = eval { my $link = readlink $active_link } or do {
            $log->critical("$active_link is not a symlink");
            exit 1;
        };

        dircopy( $orig_work_dir, $work_dir );
    }

    my $installed = {};
    foreach my $package (@packages) {
        $self->install_package( $package, $work_dir, $installed );
    }

    # We finished installing each one recursively to the work directory
    # Now we need to set the symlink
    $log->debug('Setting symlink to new work directory');
    $active_link->remove;

    if ( ! symlink $work_dir, $active_link ) {
        $log->error('Could not activate new installation (symlink failed)');
        exit 1;
    }

    $log->info("Finished installing all packages into $pakket_dir");

    # Clean up
    my $keep = $self->keep_copies;

    if ( $keep <= 0 ) {
        $log->warning(
            "You have set your 'keep_copies' to 0 or less.\n" .
            "Resetting it to '1'.\n",
        );

        $keep = 1;
    }

    my @dirs = sort { $a->stat->mtime <=> $b->stat->mtime }
               grep +( basename($_) ne 'active' && $_->is_dir ), $pakket_dir->children;

    my $num_dirs = @dirs;
    foreach my $dir (@dirs) {
        $num_dirs-- <= $keep and last;
        $log->debug("Removing old directory: $dir");
        path($dir)->remove_tree( { 'safe' => 0 } );
    }

    return;
}

sub install_package {
    my ( $self, $package, $dir, $installed ) = @_;

    $log->debug("About to install $package");

    if ( $installed->{$package}++ ) {
        $log->debug("$package already installed");
        return;
    }

    my ( $pkg_cat, $pkg_name, $pkg_ver ) = split /\//xms, $package;

    my $req   = Pakket::Version::Requirements->new_from_category($pkg_cat);
    my $index = $self->index;

    my $version = $req->pick_maximum_satisfying_version(
        [ keys %{ $index->{$pkg_cat}{$pkg_name}{'versions'} } ],
    );


    my $parcel_file = $self->parcel_dir->child(
        $pkg_cat,
        $pkg_name,
        $index->{$pkg_cat}{$pkg_name}{'versions'}{$version} . '.pkt',
    );

    if ( !$parcel_file->exists ) {
        $log->critical(
            "Bundle file '$parcel_file' does not exist or can't be read",
        );

        exit 1;
    }

    if ( !is_writeable($dir) ) {
        $log->critical(
            "Can't write to your installation directory ($dir)",
        );

        exit 1;
    }

    # FIXME: $parcel_dirname should come from repo
    my $parcel_basename = $parcel_file->basename;
    $parcel_file->copy($dir);

    $log->debug("Unpacking $parcel_basename");

    # TODO: Archive::Any might fit here, but it doesn't support XZ
    # introduce a plugin for it? It could be based on Archive::Tar
    # but I'm not sure Archive::Tar support XZ either -- SX.
    $self->run_command(
        $dir,
        [ qw< tar -xJf >, $parcel_basename ],
    );

    my $full_parcel_dir = $dir->child( PARCEL_FILES_DIR() );
    foreach my $item ( $full_parcel_dir->children ) {
        my $inner_dir = $dir->child( basename($item) );

        if ( $inner_dir->is_dir && !$inner_dir->exists ) {
            $inner_dir->mkpath();
        }

        dircopy( $item, $inner_dir );
    }

    $dir->child($parcel_basename)->remove;

    my $spec_file = $full_parcel_dir->child( PARCEL_METADATA_FILE() );

    my $config = decode_json $spec_file->slurp_utf8;

    my $prereqs = $config->{'Prereqs'};
    foreach my $prereq_category ( keys %{$prereqs} ) {
        my $runtime_prereqs = $prereqs->{$prereq_category}{'runtime'};

        foreach my $prereq_name ( keys %{$runtime_prereqs} ) {
            my $prereq_data    = $runtime_prereqs->{$prereq_name};
            my $prereq_version = $prereq_data->{'version'};

            # FIXME We shouldn't be constructing this,
            #       We should just ask the repo for it
            #       It should maintain metadata for this
            #       and API to retrieve it
            my $next_pkg = "$prereq_category/$prereq_name/$prereq_version";
            $self->install_package( $next_pkg, $dir, $installed );
        }
    }

    $full_parcel_dir->remove_tree( { 'safe' => 0 } );

    my $actual_version = $config->{'Package'}{'version'};
    $log->info("Delivered parcel $pkg_cat/$pkg_name ($actual_version)");

    return;
}

__PACKAGE__->meta->make_immutable;

no Moose;

1;

__END__
