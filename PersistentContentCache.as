/////////////////////////////////////////////////////////////////////////////////
//
//  Copyright 2013,2014 Digabit, Inc.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//  	
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//  	
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
////////////////////////////////////////////////////////////////////////////////

/* 
* Project : DocuMobile
* Author  : Josh Weinberg, Digabit Inc.
* Created : Apr 16, 2013 10:32:12 AM
*/
package com.digabit.supportClasses
{
import flash.display.Loader;
import flash.events.Event;
import flash.events.FileListEvent;
import flash.events.HTTPStatusEvent;
import flash.events.IOErrorEvent;
import flash.events.SecurityErrorEvent;
import flash.events.TimerEvent;
import flash.filesystem.File;
import flash.filesystem.FileMode;
import flash.filesystem.FileStream;
import flash.net.URLLoader;
import flash.net.URLLoaderDataFormat;
import flash.net.URLRequest;
import flash.system.LoaderContext;
import flash.utils.ByteArray;
import flash.utils.Dictionary;
import flash.utils.Timer;
import flash.utils.getQualifiedClassName;

import mx.logging.ILogger;
import mx.logging.Log;
import mx.utils.Base64Encoder;
import mx.utils.SHA256;
import mx.utils.UIDUtil;

import spark.core.ContentCache;
import spark.core.ContentRequest;

/**
 * Adds a disk-based cache to the in-memory caching ContentCache. Content is attempted
 * to be found in the memory cache first, then the disk cache and finally from
 * the network.
 * 
 *  @playerversion AIR 3.7
 */
public class PersistentContentCache extends ContentCache
{
	
	//--------------------------------------------------------------------------
	//
	//  Static Class Constants
	//
	//--------------------------------------------------------------------------
	
	/**
	 * Log static initializer
	 */
	private static var log:ILogger
	{
		log = Log.getLogger(getQualifiedClassName(com.digabit.supportClasses.PersistentContentCache).replace("::", "."));
	}
	
	/**
	 * Maintain the cache every two minutes.
	 */
	private const MAINTENANCE_INTERVAL:Number = 2*60*1000;
	
	//--------------------------------------------------------------------------
	//
	//  Constructor
	//
	//--------------------------------------------------------------------------
	
	/**
	 * Constructor.
	 * 
	 * @param cacheSubDir Directory name in File.cacheDirectory
	 * 			(or File.applicationStoragerDirectory on non-mobile) where cache is stored.
	 */
	public function PersistentContentCache(cacheSubDir:String = "HCC")
	{
		super();
		
		this.maxCacheEntries = 50;
		this.cacheSubDir = cacheSubDir;
		
		setupCache();
		doMaintenance();
	}
	
	//--------------------------------------------------------------------------
	//
	//  Variables
	//
	//--------------------------------------------------------------------------
	
	//----------------------------------
	//  cacheSubDir
	//----------------------------------
	
	/**
	 * Cache subdir
	 */
	private var cacheSubDir:String;
	
	//----------------------------------
	//  pendingRequestDict
	//----------------------------------
	
	/**
	 * Pending URLLoader requests. Key is URLLoader object associated with
	 * the request.
	 */
	private var pendingRequestDict:Dictionary = new Dictionary();
	
	//----------------------------------
	//  base64Encoder
	//----------------------------------
	
	/**
	 * Base64Encoder
	 */
	private var base64Encoder:Base64Encoder = new Base64Encoder();
	
	//----------------------------------
	//  cacheDir
	//----------------------------------
	
	/**
	 * cacheDir
	 */
	private var cacheDir:File;
	
	//----------------------------------
	//  cacheDirHasEventListeners
	//----------------------------------
	
	/**
	 * cacheDirHasEventListeners
	 */
	private var cacheDirHasEventListeners:Boolean;
	
	//----------------------------------
	//  maintenanceTimer
	//----------------------------------
	
	/**
	 * maintenanceTimer
	 */
	private var maintenanceTimer:Timer;
	
	//----------------------------------
	//  maintaining
	//----------------------------------
	
	/**
	 * maintaining
	 */
	private var maintaining:Boolean;
	
	//----------------------------------
	//  resourceLoadFailureDict
	//----------------------------------
	
	/**
	 * Dictionary to track failed resources 
	 */
	private var resourceLoadFailureDict:Dictionary;
	
	//----------------------------------
	//  delayedErrorTimer
	//----------------------------------
	
	/**
	 * delayedErrorTimer
	 */
	private var delayedErrorTimer:Timer;
	
	//----------------------------------
	//  pendingErroredRequests
	//----------------------------------
	
	/**
	 * ContentRequest objects which need to have an IOErrorEvent dispatched
	 * on them when the delayedErrorTimer completes.
	 */
	private var pendingErroredRequests:Vector.<ContentRequest>;
	
	//--------------------------------------------------------------------------
	//
	//  Properties
	//
	//--------------------------------------------------------------------------
	
	//----------------------------------
	//  maxCachedFileAge
	//----------------------------------
	
	/**
	 * Maximum seconds to retain a file in the disk-cache.
	 * 
	 * @default 86400 (one day).
	 */
	public var maxCachedFileAge:uint = 60*60*24;
	
	//----------------------------------
	//  maxCachedFiles
	//----------------------------------
	
	/**
	 * Maximum files to cache in disk-cache.
	 * 
	 * @default 200
	 */
	public var maxCachedFiles:uint = 200;
	
	//----------------------------------
	//  enableDiskCaching
	//----------------------------------
	
	/**
	 * @private
	 * Storage for the enableDiskCaching property.
	 */
	private var _enableDiskCaching:Boolean = true;
	
	/**
	 * Enabled the disk based caching mechanism. May be turned off internally
	 * if initialization fails.
	 * 
	 * @default true
	 */
	public function get enableDiskCaching():Boolean
	{
		return _enableDiskCaching;
	}
	
	/**
	 * @private
	 */
	public function set enableDiskCaching(value:Boolean):void
	{
		if (_enableDiskCaching == value)
			return;
		_enableDiskCaching = value;
		
		if (value == false)
		{
			log.info("Disabling disk caching");
			if (maintenanceTimer is Timer)
			{
				maintenanceTimer.removeEventListener(TimerEvent.TIMER, maintenanceTimerHandler);
				maintenanceTimer.stop();
				maintenanceTimer = null;
			}
			
			removeCacheDirEventListeners();
		}
	}
	
	//----------------------------------
	//  cacheResourceLoadFailures
	//----------------------------------
	
	/**
	 * @private
	 * Storage for the cacheResourceLoadFailures property.
	 */
	private var _cacheResourceLoadFailures:Boolean;
	
	/**
	 * If true the the cache will include failed resources where if a resource fails to load
	 * the cache will return a null value for it on subsequent accesses. This reduces
	 * the need to hit the network for unavailable resources when they may be attempted
	 * many times in a short period.
	 * 
	 * <p>A Bitmap in an itemrenderer in a list for example will attempt to load its source
	 * every time it comes into view - if the resource is unavailable it still must wait
	 * for the server to return a 404 which wastes time and resources.</p>
	 * 
	 * @see #failureCacheTimeout
	 */
	public function get cacheResourceLoadFailures():Boolean
	{
		return _cacheResourceLoadFailures;
	}
	
	/**
	 * cacheResourceLoadFailures
	 * 
	 * @private
	 */
	public function set cacheResourceLoadFailures(value:Boolean):void
	{
		if (_cacheResourceLoadFailures == value)
			return;
		_cacheResourceLoadFailures = value;
		
		if (_cacheResourceLoadFailures && !resourceLoadFailureDict)
		{
			resourceLoadFailureDict = new Dictionary();
		}
		else if (!_cacheResourceLoadFailures && resourceLoadFailureDict)
		{
			resourceLoadFailureDict = null;
		}
	}
	
	//----------------------------------
	//  maxCachedFailAge
	//----------------------------------
	
	/**
	 * failureCacheTimeout: Miliseconds to keep resource load failure in cache.
	 * 
	 * @default 30000 (10 minutes)
	 */
	public var failureCacheTimeout:Number = 1000*60*10;
	
	//--------------------------------------------------------------------------
	//
	//  Overridden methods
	//
	//--------------------------------------------------------------------------
	
	/**
	 * Remove both disk and memory cache entries.
	 */
	override public function removeAllCacheEntries():void
	{
		removeAllDiskCacheEntries();
		super.removeAllCacheEntries();
	}
	
	/**
	 * Remove both disk and memory cache entry.
	 * 
	 * @inheritDoc
	 */
	override public function removeCacheEntry(source:Object):void
	{
		// Attempt to remove from disk cache
		var url:String = source as String;
		if (url)
		{
			var file:File = new File(getPath(url));
			if (file.exists)
			{
				try
				{
					file.deleteFile();
				}
				catch (e:Error)
				{
					// Nothing to do but complain
					log.error("Cannot remove file from disk cache: "+file.nativePath);
				}
			}
		}
		
		// Remove from memory cache
		super.removeCacheEntry(source);
	}
	
	//--------------------------------------------------------------------------
	//
	//  Methods
	//
	//--------------------------------------------------------------------------
	
	/**
	 * Setup cache directory. Attempts to use the File.cacheDirectory first.
	 * Fallback to applicationStorageDirectory.
	 * 
	 * @private
	 */
	protected function setupCache():void
	{
		var cacheBaseDir:File;
		
		if (!enableDiskCaching)
		{
			return;
		}
		
		log.debug("Setting up cache directory");
		
		try
		{
			// This may fail if not on mobile or using wrong AIR runtime
			cacheBaseDir = File.cacheDirectory;
		}
		catch (e:Error) {
			log.warn("No File.cacheDirectory");
		}
		
		if (!cacheBaseDir)
		{
			// Fallback to applicationStorageDirectory
			cacheBaseDir = File.applicationStorageDirectory;
		}
		
		if (cacheDir)
		{
			removeCacheDirEventListeners();
		}
		
		try
		{
			cacheDir = cacheBaseDir.resolvePath(cacheSubDir);
		}
		catch (e:Error)
		{
			log.error("Cannot resolve cacheSubDir");
			enableDiskCaching = false;
			return;
		}
		
		if (!cacheDir.exists)
		{
			try
			{
				cacheDir.createDirectory();
				if (cacheDir.hasOwnProperty("preventBackup"))
				{
					cacheDir.preventBackup = true;
				}
			}
			catch (e:Error)
			{
				log.error("Cannot create cacheDir");
				enableDiskCaching = false;
				return;
			}
			
		}
		
		if (!cacheDir.isDirectory)
		{
			enableDiskCaching = false;
			return;
		}
		
		// Test write to cache dir
		try
		{
			var testFile:File = cacheDir.resolvePath(UIDUtil.createUID());
			var testFileStream:FileStream = new FileStream();
			testFileStream.open(testFile, FileMode.WRITE);
			testFileStream.writeBoolean(true);
			testFileStream.close();
			testFile.deleteFile();
		}
		catch (e:Error)
		{
			// Any errors in the above block mean disk-caching is going to fail.
			log.error("Cannot write to cacheDir");
			enableDiskCaching = false;
			return;
		}
		
		addCacheDirEventListeners();
	}
	
	/**
	 * Add eventlisteners to cacheDir for directory listing and errors
	 */
	private function addCacheDirEventListeners():void
	{
		if (!cacheDirHasEventListeners)
		{
			cacheDir.addEventListener(FileListEvent.DIRECTORY_LISTING, cacheDirListing_handler, false, 0, true);
			cacheDir.addEventListener(IOErrorEvent.DISK_ERROR, cacheDirListing_errorHandler, false, 0, true);
			cacheDir.addEventListener(IOErrorEvent.IO_ERROR, cacheDirListing_errorHandler, false, 0, true);
			cacheDirHasEventListeners = true;
		}
	}
	
	/**
	 * Remove eventlisteners from cacheDir.
	 */
	private function removeCacheDirEventListeners():void
	{
		if (cacheDir && cacheDirHasEventListeners)
		{
			cacheDir.removeEventListener(FileListEvent.DIRECTORY_LISTING, cacheDirListing_handler);
			cacheDir.removeEventListener(IOErrorEvent.DISK_ERROR, cacheDirListing_errorHandler);
			cacheDir.removeEventListener(IOErrorEvent.IO_ERROR, cacheDirListing_errorHandler);
			cacheDirHasEventListeners = false;
		}
	}
	
	/**
	 * Returns the filename to use in the cache for a given url
	 */
	private function getCacheFilenameForUrl(url:String):String
	{
		var b:ByteArray = new ByteArray();
		b.writeUTF(url);
		b.position = 0;
		return encodeURIComponent(SHA256.computeDigest(b));
	}
	
	/**
	 * Return URI to cached file in local disk cache.
	 * This is in URI format like appStorageDir:/dir/file.
	 */
	protected function getPath(url:String):String
	{
		var file:File = cacheDir.resolvePath(getCacheFilenameForUrl(url));
		return file.url;
	}
	
	/**
	 * True if the URL exists in the disk cache.
	 */
	private function inDiskCache(url:String):Boolean
	{
		if (cacheResourceLoadFailures && resourceLoadFailureDict[url])
			return true;
		
		var file:File = cacheDir.resolvePath(getCacheFilenameForUrl(url));
		
		return file.exists;
	}
	
	/**
	 * Delete the disk cache.
	 */
	public function removeAllDiskCacheEntries():void
	{
		if (!enableDiskCaching)
			return;
		
		if (cacheDir && cacheDir.exists)
		{
			cacheDir.deleteDirectory(true);
		}
		setupCache();
	}
	
	/**
	 * Load a resource using URLLoader in order to cache the content on disk.
	 * 
	 * @param url The source of the content
	 */
	protected function urlLoad(url:String, contentLoaderGrouping:String=null):ContentRequest
	{
		var urlLoader:URLLoader = new URLLoader();
		urlLoader.dataFormat = URLLoaderDataFormat.BINARY;
		
		urlLoader.addEventListener(Event.COMPLETE, urlLoader_completeHandler, false, 0, true);
		urlLoader.addEventListener(IOErrorEvent.IO_ERROR, urlLoader_completeHandler, false, 0, true);
		urlLoader.addEventListener(IOErrorEvent.NETWORK_ERROR, urlLoader_completeHandler, false, 0, true);
		urlLoader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, urlLoader_completeHandler, false, 0, true);
		urlLoader.addEventListener(HTTPStatusEvent.HTTP_STATUS, urlLoader_completeHandler, false, 0, true);
		
		var urlRequest:URLRequest = new URLRequest(url);
		
		// Make a loader to be returned with the contentRequest. This loader will eventually be used
		// to load the content out of the disk-cache once it has been placed there.
		var loader:Loader = new Loader();
		
		// Cache our new LoaderInfo if applicable.
		if (enableCaching) 
		{
			addCacheEntry(url, loader.contentLoaderInfo);
			
			// Mark entry as incomplete, ContentCache will mark as complete later
			// once fully loaded.
			var entry:Object = cachedData[url] as Object;
			if (entry)
			{
				entry.complete = false;
			}
		}
		
		// Create ContentRequest instance to return to caller.
		var contentRequest:ContentRequest = new ContentRequest(this, loader.contentLoaderInfo, true, false);
		
		// Keep track of url, contentRequest and loader for this urlLoader request
		pendingRequestDict[urlLoader] = new PendingRequest(contentRequest, loader, url);
		
		// Execute Loader
		urlLoader.load(urlRequest);
		
		return contentRequest;
	}
	
	/**
	 * Load newly cached content from disk using the Loader created in urlLoad().
	 * 
	 * @param urlLoader Key to lookup the loader
	 */
	protected function reLoad(urlLoader:URLLoader):void
	{
		var pendingRequest:PendingRequest = pendingRequestDict[urlLoader];
		
		// Load from the disk cache
		var path:String = getPath(pendingRequest.url);
		var urlRequest:URLRequest = new URLRequest(path);
		
		// Execute Loader
		var loaderContext:LoaderContext = new LoaderContext();
		loaderContext.checkPolicyFile = true;
		
		// Add event handler to the loader's contentLoaderInfo
		pendingRequest.loader.contentLoaderInfo.addEventListener(IOErrorEvent.IO_ERROR, reload_ioErrorHandler, false, 0, true);
		pendingRequest.loader.load(urlRequest, loaderContext);
	}
	
	/**
	 * Periodically run maintain on the cache
	 */
	protected function maintainCache():void
	{
		if (!maintenanceTimer && enableDiskCaching)
		{
			maintenanceTimer = new Timer(MAINTENANCE_INTERVAL,0);
			maintenanceTimer.addEventListener(TimerEvent.TIMER, maintenanceTimerHandler, false, 0, true);
			maintenanceTimer.start();
		}
	}
	
	/**
	 * Purge expired failures from fail cache
	 */
	private function maintainFailCache():void
	{
		var keys:Array = [];
		var key:*;
		var now:Date = new Date();
		
		// First find expired keys and then remove them so we don't alter the
		// dictionary as we are iterating through it.
		for (key in resourceLoadFailureDict)
		{
			var lastAttempt:Number = resourceLoadFailureDict[key] as Number;
			if (lastAttempt)
			{
				if ((now.time - failureCacheTimeout) > lastAttempt)
				{
					log.debug("Fail cache entry expired. Purging: "+key as String);
					keys.push(key);
				}
			}
		}
		
		for each (key in keys)
		{
			delete resourceLoadFailureDict[key];
		}
	}
	
	/**
	 * Adds the byteArray to the disk cache with the given source lookup key.
	 * 
	 * @param source URL string this cache entry will be referenced by.
	 * @param value ByteArray representing the cached item (PNG, JPEG, etc)
	 * @param overwrite If true will overwrite a currently cached entry if it exists.
	 */
	public function addDiskCacheEntry(source:String, value:ByteArray, overwrite:Boolean = false):Boolean
	{
		var file:File = cacheDir.resolvePath(getCacheFilenameForUrl(source));
		
		if (file.exists && !overwrite)
			return true;
		
		var fileStream:FileStream = new FileStream();
		log.debug("Caching URL:"+source+" => PATH:"+file.nativePath);
		try
		{
			fileStream.open(file, FileMode.WRITE);
			fileStream.writeBytes(value);
			fileStream.close();
		}
		catch (e:Error)
		{
			log.error("Cache Fail. Cannot write to "+file.nativePath);
			return false;
		}
		
		return true;
	}
	
	/**
	 * <p>Adds a cache entry to the Fail cache.</p>
	 * 
	 * @param url The URL associated with the failed resource.
	 */
	public function addFailCacheEntry(url:String):void
	{
		var now:Date = new Date();
		resourceLoadFailureDict[url] = now.time;
		
		log.debug("Added entry to fail cache for URL: "+url);
	}
	
	/**
	 * Handles maintenance of the cache. Don't call directly,
	 * call maintainCache() instead to handle the maintenance timer.
	 */
	private function doMaintenance():void
	{
		if (!maintaining && enableDiskCaching)
		{
			log.debug("Maintain cache");
			maintaining = true;
			if (maintenanceTimer)
				maintenanceTimer.stop();
			
			if (cacheResourceLoadFailures)
				maintainFailCache();
			
			cacheDir.getDirectoryListingAsync(); 
		}
	}
	
	/**
	 * Dispatch an IOErrorEvent on the contentRequest object. We must delay sending
	 * the error so the calling class (BitmapImage generally) has a chance to add its
	 * event listeners to the returned ContentRequest object.
	 * 
	 * @see spark.primitives.BitmapImage#loadExternal()
	 */
	private function dispatchIOErrorEvent(contentRequest:ContentRequest):void
	{
		//log.debug("dispatchIOErrorEvent");
		
		if (!delayedErrorTimer)
		{
			delayedErrorTimer = new Timer(20,1);
			delayedErrorTimer.addEventListener(TimerEvent.TIMER_COMPLETE, sendErrorHandler, false, 0, true);
		}
		
		if (!delayedErrorTimer.running)
		{
			delayedErrorTimer.reset();
			delayedErrorTimer.start();
		}
		
		if (!pendingErroredRequests)
			pendingErroredRequests = new Vector.<ContentRequest>;
		
		pendingErroredRequests.push(contentRequest);
	}
	
	//--------------------------------------------------------------------------
	//
	//  Overridden methods
	//
	//--------------------------------------------------------------------------
	
	/**
	 * Implement disk-cache on top of ContentCache.<br>
	 * 
	 * @inheritDoc
	 */
	override public function load(source:Object, contentLoaderGrouping:String=null):ContentRequest
	{
		maintainCache();
		
		var url:String = source as String;
		
		// We can only handle url strings (not URLRequests) as a source so
		// we pass non-strings to the parent class. Also if disk based caching
		// is disabled we just fallback to in-memory caching by handing all requests
		// to ContentCache.load().
		if (!url || !enableDiskCaching)
		{
			return super.load(source, contentLoaderGrouping);
		}
		
		if (cacheResourceLoadFailures)
		{
			// Check the fail cache for a recent load attempt for this resource which failed.
			
			var lastAttempt:Number = resourceLoadFailureDict[url] as Number;
			if (lastAttempt)
			{
				var now:Date = new Date();
				
				if ((now.time - failureCacheTimeout) < lastAttempt)
				{
					//log.debug("Fail Cache hit for URL: "+url);
					var contentRequest:ContentRequest = new ContentRequest(this, null, true, false);
					
					// Dispatch a delayed IOErrorEvent on the contentRequest to signal the failure
					dispatchIOErrorEvent(contentRequest);
					
					return contentRequest;
				}
				else
				{
					//log.debug("Fail Cache timeout exceeded for URL: "+url);
				}
			}
		}
		
		for (var i:* in pendingRequestDict)
		{
			var pendingRequest:PendingRequest = pendingRequestDict[i];
			
			if (pendingRequest.url == url) 
			{
				log.debug("Current request for this URL is pending.");
				return pendingRequest.contentRequest;
			}
		}
		
		// Determine the path this source URL would have in the cache
		var path:String = getPath(url);
		
		// Case 1a: Content exists in ContentCache at URL.
		if (cachedData[url] && cachedData[url].complete)
		{
			//log.debug("1A - Content in ContentCache at "+url);
			return super.load(url, contentLoaderGrouping);
		}
		
		// Case 1b: Content exists in ContentCache at path.
		if (cachedData[path] && cachedData[path].complete)
		{
			//log.debug("1B - Content in ContentCache at "+path);
			return super.load(path, contentLoaderGrouping);
		}
		
		// Case 2: Data is not in memory but in disk cache. We load the
		// 			cached content from disk using the ContentCache which
		// 			results in an in-memory copy of the disk-cached content.
		if (inDiskCache(url))
		{
			//log.debug(" 2 - Content in Disk Cache at "+path);
			return super.load(path, contentLoaderGrouping);
		}
		
		// Case 3: Data is in neither cache. Load with an URLLoader and put result in the disk cache.
		//log.debug(" 3 - Content in no caches. Loading with URLLoader.");
		return urlLoad(url, contentLoaderGrouping);
		
	}
	
	/**
	 * NB: If the entry exists in the cache we return "true" instead of the actual entry.
	 * This is a debatable action since it does not fulfill the definition of the overriden
	 * method. However - the only place this is called in the whole Flex SDK is from
	 * IconItemRenderer.as:setIconDisplaySource() and the resulting value is only checked for
	 * non-null. In the case of the in-memory content cache this really does not represent
	 * a performance problem since it's just returning a pointer to the object. In our
	 * case we would have to load the actual data off the disk which would be considerably 
	 * slower. So we cheat and just return a non-null value for performance reasons.
	 * <br>
	 * 
	 * @inheritDoc
	 */
	override public function getCacheEntry(source:Object):Object
	{
		if (source is String)
		{
			if (cacheResourceLoadFailures && resourceLoadFailureDict[source])
			{
				return null;
			}
			
			if (inDiskCache(source as String))
			{
				return true;
			}
		}
		
		return super.getCacheEntry(source);
	}
	
	//--------------------------------------------------------------------------
	//
	//  Event handlers
	//
	//--------------------------------------------------------------------------
	
	/**
	 * URLLoader has loaded our object. Write it to the disk cache.
	 * 
	 * @private
	 */
	private function urlLoader_completeHandler(event:Event):void
	{
		var urlLoader:URLLoader = event.currentTarget as URLLoader;
		var now:Date;
		
		if (!urlLoader.data)
			return;
		
		if (urlLoader)
		{
			var pendingRequest:PendingRequest = pendingRequestDict[urlLoader];
			
			if (event.type == IOErrorEvent.IO_ERROR || event.type == SecurityErrorEvent.SECURITY_ERROR ||
				event.type == IOErrorEvent.NETWORK_ERROR)
			{
				//log.debug("Error loading resource from network. "+event.toString());
				
				if (cacheResourceLoadFailures)
				{
					addFailCacheEntry(pendingRequest.url);
				}
				
				// Nothing was loaded. Dispatch error to the ContentRequest
				var contentRequest:ContentRequest = pendingRequest.contentRequest;
				
				if (contentRequest.hasEventListener(event.type))
				{
					contentRequest.dispatchEvent(event);
				}
			}
			else
			{
				log.debug("Load from network complete.");
				
				var cacheResult:Boolean = addDiskCacheEntry(pendingRequest.url, urlLoader.data);
				
				if (!cacheResult)
				{
					// Failed to cache
					enableDiskCaching = false;
				}
				else
				{
					reLoad(urlLoader);
				}
			}
			
			delete pendingRequestDict[urlLoader];
			
			urlLoader.removeEventListener(Event.COMPLETE, urlLoader_completeHandler);
			urlLoader.removeEventListener(IOErrorEvent.IO_ERROR, urlLoader_completeHandler);
			urlLoader.removeEventListener(IOErrorEvent.NETWORK_ERROR, urlLoader_completeHandler);
			urlLoader.removeEventListener(SecurityErrorEvent.SECURITY_ERROR, urlLoader_completeHandler);
			urlLoader.removeEventListener(HTTPStatusEvent.HTTP_STATUS, urlLoader_completeHandler);
		}
		
	}
	
	/**
	 * Maintain the cache
	 * 
	 * @private
	 */
	private function maintenanceTimerHandler(event:TimerEvent):void
	{
		doMaintenance();
	}
	
	/**
	 * Load the cached directory listing asynchronously
	 * 
	 * @private
	 */
	private function cacheDirListing_handler(event:FileListEvent):void
	{
		var contents:Array = event.files;
		var now:Date = new Date();
		var file:File;
		
		// Limit number of files in cache.
		// Should really implement an LRU scheme to determine which
		// files to remove from the cache. In the meantime we apply the
		// Random Replacement algorithm.
		while (contents.length > maxCachedFiles)
		{
			var removeFile:uint = Math.floor(Math.random()*contents.length);
			
			try
			{
				file = contents[removeFile] as File;
				log.info("MaintainCache: too many files in cache ("+contents.length+" > "+maxCachedFiles+"). Deleting "+file.nativePath);
				file.deleteFile();
			}
			catch (e:Error)
			{
				log.error("Error in delete. Skipping.");
			}
			
			contents.splice(removeFile,1);
		}
		
		// Delete any remaining files older than retention time
		for (var j:uint = 0; j < contents.length; j++) 
		{
			file = contents[j] as File;
			
			if (!file.isDirectory)
			{
				var creationDate:Date = file.creationDate;
				var age:Number = (now.time - creationDate.time)/1000;
				
				if (age > maxCachedFileAge)
				{
					log.info("File expired: Age = "+age+" "+file.nativePath);
					
					try
					{
						file.deleteFile();
					}
					catch (e:Error)
					{
						log.error("Error in delete. Skipping.");
					}
				}
			}
		}
		
		maintaining = false;
		
		if (maintenanceTimer)
			maintenanceTimer.start();
	}
	
	/**
	 * Handle error in directory listing
	 * 
	 * @private
	 */
	private function cacheDirListing_errorHandler(event:IOErrorEvent):void
	{
		log.error("CacheDir listing error: "+event.toString());
		
		maintaining = false;
		
		if (event.errorID == 3003)
		{
			// Directory does not exist. Probably was removed by the OS to reclaim disk space.
			// We atttempt to reclaim it back.
			setupCache();
			
			if (enableDiskCaching)
			{
				// If disk caching wasn't disabled we resume the maintenance timer.
				maintenanceTimer.start();
			}
		}
		else
		{
			enableDiskCaching = false;
		}
	}
	
	/**
	 * Reload of data from the disk cache may fail if the cache happens to have been cleared
	 * immediately after we wrote it.
	 * 
	 * @private
	 */
	protected function reload_ioErrorHandler(event:IOErrorEvent):void
	{
		log.warn("Error received attempting to load from disk cache file: "+event.text);
	}
	
	/**
	 * Dispatch errors on all contentRequests in the pendingErroredRequests vector.
	 */
	protected function sendErrorHandler(event:TimerEvent):void
	{
		while (pendingErroredRequests.length > 0)
		{
			var contentRequest:ContentRequest = pendingErroredRequests.pop();
			if (contentRequest.hasEventListener(IOErrorEvent.IO_ERROR))
			{
				contentRequest.dispatchEvent(new IOErrorEvent(IOErrorEvent.IO_ERROR, false, false, "Persistent content cache: cached load failure"));
			}
		}
	}
	
}
}

import flash.display.Loader;

import spark.core.ContentRequest;

/**
 *  Data associated with an ongoing request
 * 
 *  @private
 */
class PendingRequest
{
	public function PendingRequest(contentRequest:ContentRequest = null, loader:Loader = null, url:String = null):void
	{
		this.contentRequest = contentRequest;
		this.loader = loader;
		this.url = url;
	}   
	
	//----------------------------------
	//  contentRequest
	//----------------------------------
	
	/**
	 * contentRequest
	 */
	public var contentRequest:ContentRequest;
	
	//----------------------------------
	//  loader
	//----------------------------------
	
	/**
	 * loader
	 */
	public var loader:Loader;
	
	//----------------------------------
	//  url
	//----------------------------------
	
	/**
	 * url
	 */
	public var url:String;
	
}