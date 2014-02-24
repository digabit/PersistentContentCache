PersistentContentCache
======================

PersistentContentCache

Extends spark.core.ContentCache to add a disk-based cache. Content is attempted
to be found in the memory cache first, then the disk cache and finally from
the network.
