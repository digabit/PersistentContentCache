
PersistentContentCache
======================

PersistentContentCache

Extends spark.core.ContentCache to add a disk-based cache. Content is attempted to be found in the memory cache first, then the disk cache and finally from the network.

Usage
=====

Use in place of the standard Spark ContentCache class. Create a static instance and assign to the iconContentLoader property of ItemRenderer.

For example, in a custom class extending ItemRenderer...

```
public class CustomItemRendererBase extends IconItemRenderer
{

	/**
	 * Static thumbnail cache and initializer
	 */
	public static var thumbnailCache:PersistentContentCache;
	{
		thumbnailCache = new PersistentContentCache("com.digabit.documobile.thumbnailCache");
		thumbnailCache.cacheResourceLoadFailures = true;
		thumbnailCache.maxCachedFiles = 200;
		thumbnailCache.maxCacheEntries = 40;
	}
	
	/**
	 * Constructor.
	 */
	public function CustomItemRendererBase()
	{
		super();
		iconContentLoader = thumbnailCache;
	}
	
	...
	
}

```

Now your custom item renderer will utilize a disk based content cache which persists across invocations of the application. In this example it also
will cache resource load failures which can improve performance and reduce network traffic when the content is not found.

License
=======

Copyright 2013,2014 Digabit, Inc.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
	
This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.
	
You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

