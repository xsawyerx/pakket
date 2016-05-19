package Pakket::Installer;

# ABSTRACT: Install pakket packages into an installation directory

use Moose;
use Path::Tiny qw< path  >;
use Types::Path::Tiny qw< Path  >;
use File::HomeDir;
use Pakket::Utils qw< is_writeable >;
use Pakket::Repository;
use namespace::autoclean;

# TODO:
# * Recursively install
# * Support .pakket.local (or .pakket.config local file configuration)
# * Support multiple libraries
# * Support active library

# Sample structure:
# ~/.pakket/
#        bin/
#        etc/
#        repos/
#        libraries/
#                  active ->
#

has repo_dir => (
    is      => 'ro',
    isa     => Path,
    coerce  => 1,
    default => sub {
        # if it's installed:
        #   * PAKKET_REPO will be configured
        #   * if we have permission, we will install to it successfully
        # if it isn't installed:
        #   * this is a local installation
        $ENV{'PAKKET_REPO'} || path( File::HomeDir->my_home, '.pakket' );
    },
);

has repo => (
    is      => 'ro',
    isa     => 'Pakket::Repository',
    lazy    => 1,
    builder => '_build_repo',
);

has install_dir => (
    is      => 'ro',
    isa     => Path,
    lazy    => 1,
    coerce  => 1,
    default => sub {
        my $self = shift;
        return path( $self->repo_dir, 'library' );
    },
);

sub _build_repo {
    my $self = shift;
    return Pakket::Repository->new( repo_dir => $self->repo_dir );
}

# TODO:
# this should be implemented using a fetcher class
# because it might be from HTTP/FTP/Git/Custom/etc.
sub fetch_package;

sub install_file {
    my ( $self, $filename ) = @_;

    my $bundle_file = path($filename);

    if ( !-r $bundle_file ) {
        exit log_critical { $_[0] }
        "Bundle file '$filename' does not exist or can't be read\n";
    }

    my $install_dir = $self->install_dir;

    if ( !$install_dir->is_dir ) {
        exit log_critical { $_[0] }
        'Cannot find library directory, please run \'init\' first';
    }

    if ( !is_writeable($install_dir) ) {
        exit log_critical { $_[0] }
        "Can't write to your installation directory ($install_dir)";
    }

    my $bundle_basename = $bundle_file->basename;
    $bundle_file->copy($install_dir);

    # TODO: Archive::Any might fit here, but it doesn't support XZ
    # introduce a plugin for it? It could be based on Archive::Tar
    # but I'm not sure Archive::Tar support XZ either -- SX.
    System::Command->spawn( qw< tar -xJf >, $bundle_basename,
        { cwd => $install_dir },
    );

    $install_dir->child($bundle_basename)->remove;

    print "Installed $bundle_basename in $install_dir\n";
}

__PACKAGE__->meta->make_immutable;

1;

__END__