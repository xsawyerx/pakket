package Pakket::Role::Repository::Backend;

# ABSTRACT: A role for all repository backends

use v5.22;
use Moose::Role;
use namespace::autoclean;

# These are helper methods we want the backend to implement
# in order for the Repository to easily use across any backend
requires qw(
    new_from_uri
    all_object_ids all_object_ids_by_name has_object
    store_content retrieve_content store_location
    retrieve_location remove
);

1;

__END__
