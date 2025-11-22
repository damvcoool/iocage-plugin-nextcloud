# Performance Optimization Guide

This document outlines the performance optimizations implemented for the Nextcloud iocage plugin, specifically targeting PHP 8.4, Redis, Nginx, and MySQL configurations.

## Summary of Changes

All configuration files have been optimized with performance in mind. Below is a summary of the key improvements:

### PHP 8.4 Optimizations (`overlay/usr/local/etc/php/php.truenas.ini`)

**OPcache Improvements:**
- Increased memory consumption from 512MB to 1GB for larger codebases
- Increased interned strings buffer from 64MB to 128MB for more string caching
- Increased max accelerated files from 10,000 to 100,000 for larger projects
- Increased JIT buffer from 128MB to 256MB for better JIT performance
- Added file cache at `/var/cache/opcache` for persistent OPcache across restarts
- Enabled fast shutdown for improved performance

**APCu Enhancements:**
- Increased APCu memory from default to 256MB for better local caching
- Added TTL (7200s) for APCu entries
- Enabled slam defense to prevent cache stampedes

**PHP Runtime:**
- Increased max execution time to 3600s for large operations
- Optimized realpath cache (4096K size, 600s TTL) to reduce filesystem calls

### PHP-FPM Optimizations (`overlay/usr/local/etc/php-fpm.d/nextcloud.conf`)

**Process Management:**
- Increased listen backlog to 511 for high-traffic scenarios
- Set max requests per child to 1000 to prevent memory leaks
- Enabled process manager status page at /fpm-status

**Performance Settings:**
- Configured request timeouts (3600s) for long-running operations
- Added slowlog (30s threshold) for performance monitoring
- Configured emergency restart threshold (10 in 1 minute)
- Enabled catch_workers_output for better debugging
- Added environment variables for optimal performance

### Redis Configuration (`overlay/usr/local/etc/redis/redis.conf`)

**New Configuration File:**
A comprehensive Redis configuration has been added with the following optimizations:

**Memory Management:**
- Set maxmemory to 512MB (adjustable based on system resources: 512-800MB for 8GB systems, 1-1.5GB for 16GB systems)
- Configured allkeys-lru eviction policy for optimal cache management
- Optimized data structure settings for memory efficiency

**Performance Features:**
- Disabled AOF (Append Only File) by default for better write performance
- Configured intelligent persistence with RDB snapshots
- Set dynamic HZ for reduced latency
- Increased max clients to 10,000
- Optimized client output buffer limits
- Enabled active rehashing for better memory efficiency

**Monitoring:**
- Configured slowlog (10ms threshold) for performance analysis
- Added comprehensive logging at /var/log/redis/redis.log

### Nginx Main Configuration (`overlay/usr/local/etc/nginx/nginx.conf`)

**Worker Optimization:**
- Increased worker connections from 1,024 to 4,096 for better concurrency
- Set worker priority to -5 for higher CPU priority
- Increased worker_rlimit_nofile to 65,535 for handling more open files
- Disabled accept_mutex for better performance with modern kernels

**Buffer and Timeout Settings:**
- Increased client_max_body_size from 100M to 512M for larger file uploads
- Increased client_body_buffer_size from 1M to 2M
- Optimized proxy buffers (16x32k) for better throughput
- Added server_names_hash_bucket_size for better hostname handling

**FastCGI Caching:**
- Added comprehensive FastCGI cache configuration at `/var/tmp/nginx/fastcgi_cache`
- Set cache path with 256MB zone and 1GB max size
- Cache zone is configured but not enabled by default to avoid session management issues
- Can be enabled with appropriate cache bypass rules for dynamic content
- Cache directories are automatically created during installation

**File Caching:**
- Added open_file_cache (10,000 files, 30s inactive)
- Configured cache validation every 60s
- Enabled caching of file errors

**SSL Performance:**
- Increased SSL session cache from 10MB to 50MB (~200,000 sessions)
- Added ssl_buffer_size optimization (4k) for reduced latency

### Nginx Nextcloud Configuration (`overlay/usr/local/etc/nginx/conf.d/nextcloud.inc`)

**FastCGI Optimization:**
- Increased fastcgi_buffers from 64x4K to 128x4K for better throughput
- Added fastcgi_buffer_size (8k) and busy_buffers_size (16k) configuration
- Configured FastCGI timeouts (60s connect, 180s send/read)

**Static Asset Caching:**
- Extended cache time for immutable assets from 6 months to 1 year
- Optimized font file caching from 7 days to 90 days with immutable flag
- Added TCP optimization (tcp_nopush, tcp_nodelay) for static content

**Client Settings:**
- Increased client_body_buffer_size from 512K to 1M for better HTTP2 performance

### MySQL Configuration (`overlay/usr/local/etc/mysql/conf.d/my.cnf`)

**InnoDB Optimizations:**
- Increased innodb_buffer_pool_size from 1GB to 2GB for better caching
- Added innodb_buffer_pool_instances (2) for better concurrency
- Increased innodb_redo_log_capacity from 512MB to 1GB
- Increased IO threads from 8 to 16 each (read and write)
- Set innodb_flush_log_at_trx_commit to 2 for better performance
- Enabled innodb_file_per_table for better space management

**Connection and Cache Settings:**
- Increased max_connections from default to 300
- Set max_connect_errors to 100,000
- Added thread_cache_size (50) for connection reuse
- Query cache removed (MySQL 8.0+ default behavior)

**Table and File Handling:**
- Increased open_files_limit from 32,768 to 65,535
- Increased table_open_cache from 16,384 to 32,768
- Increased table_definition_cache from 8,192 to 16,384

**Buffer Optimizations:**
- Set sort_buffer_size to 4M
- Set read_buffer_size to 2M
- Set read_rnd_buffer_size to 8M
- Set join_buffer_size to 4M
- Set tmp_table_size and max_heap_table_size to 128M

### Nextcloud PHP Configuration (`overlay/root/config/truenas.config.php`)

**Redis Integration:**
- Added explicit port configuration (6379)
- Set connection timeout to 0.5s for quick failover
- Configured dbindex (0) for Redis database selection

## Performance Recommendations

### 1. System Resources
The optimized configurations assume the following minimum system resources:
- **RAM:** 8GB minimum (16GB recommended)
- **CPU:** 4 cores minimum (8 cores recommended)
- **Storage:** SSD recommended for database and cache

### 2. Adjustable Settings

Based on your system resources, you may want to adjust:

**For systems with less memory (< 8GB):**
- Reduce `innodb_buffer_pool_size` in my.cnf (e.g., to 1GB)
- Reduce `maxmemory` in redis.conf (e.g., to 256MB)
- Reduce `opcache.memory_consumption` in php.truenas.ini (e.g., to 512MB)
- Reduce `worker_connections` in nginx.conf (e.g., to 2048)

**For systems with more memory (> 16GB):**
- Increase `innodb_buffer_pool_size` (e.g., to 4GB or 8GB)
- Increase `maxmemory` in redis.conf (e.g., to 1GB or 2GB)
- Increase `opcache.memory_consumption` (e.g., to 2GB)
- Increase `worker_connections` (e.g., to 8192)

### 3. Monitoring

Monitor the following to ensure optimal performance:

**PHP-FPM:**
- Check `/fpm-status` for process manager status
- Monitor `/var/log/php-fpm-slow.log` for slow requests

**Redis:**
- Use `redis-cli info` to check memory usage and hit rates
- Monitor `/var/log/redis/redis.log` for issues
- Use `redis-cli slowlog get` to identify slow operations

**Nginx:**
- Monitor `/var/log/nginx/access.log` and `/var/log/nginx/error.log`
- Check FastCGI cache hit rates in logs
- Monitor worker connections and active connections

**MySQL:**
- Monitor slow query log for optimization opportunities
- Check InnoDB buffer pool usage with `SHOW ENGINE INNODB STATUS`
- Monitor connection usage with `SHOW PROCESSLIST`

### 4. Further Optimizations

**For Pure Caching (Redis):**
If you don't need Redis persistence, uncomment the following in redis.conf:
```
save ""
appendonly no
```

**For Advanced FastCGI Caching:**
To enable FastCGI caching for static Nextcloud pages (use with caution):
1. Add to the PHP location block in your Nextcloud virtual host:
   ```
   fastcgi_cache NEXTCLOUD;
   fastcgi_cache_valid 200 60m;
   fastcgi_cache_bypass $skip_cache;
   fastcgi_no_cache $skip_cache;
   ```
2. Configure cache bypass for dynamic content (login, API calls, etc.)

**For HTTP/2 Optimization:**
Ensure HTTP/2 is enabled in your Nextcloud Nginx virtual host configuration.

**For Large File Uploads:**
If you need to upload files larger than 512MB:
- Increase `client_max_body_size` in nginx.conf and nextcloud.inc
- Increase `post_max_size` and `upload_max_filesize` in php.truenas.ini
- Increase `max_allowed_packet` in my.cnf

### 5. Security Considerations

While these optimizations focus on performance, they maintain security best practices:
- Redis is bound to localhost only with protected mode enabled
- All services use appropriate permissions
- Slow query logging helps identify potential SQL injection attempts
- FastCGI caching is disabled by default to avoid session management issues
- Cache directories are created with appropriate ownership and permissions

## Testing Performance

After applying these optimizations:

1. **Cache directories are automatically created:**
   The installation script (`post_install.sh`) creates the following directories:
   - `/var/cache/opcache` for PHP OPcache file cache
   - `/var/tmp/nginx/fastcgi_cache` for Nginx FastCGI cache

2. **Clear all caches:**
   ```bash
   service redis restart
   service php-fpm restart
   service nginx restart
   ```

3. **Test Nextcloud performance:**
   - Use the Nextcloud admin panel to run a system check
   - Test file upload/download speeds
   - Monitor response times for various operations

3. **Verify OPcache is working:**
   ```bash
   php -v  # Should show JIT enabled
   ```

4. **Check Redis connectivity:**
   ```bash
   redis-cli ping  # Should return PONG
   ```

## Conclusion

These optimizations provide a solid foundation for high-performance Nextcloud deployment on FreeBSD/TrueNAS. The configurations are well-commented, allowing administrators to further tune based on their specific workload and hardware capabilities.

For additional performance tuning, refer to:
- [Nextcloud Server Tuning Guide](https://docs.nextcloud.com/server/latest/admin_manual/installation/server_tuning.html)
- [PHP OPcache Documentation](https://www.php.net/manual/en/book.opcache.php)
- [Redis Performance Tuning](https://redis.io/docs/management/optimization/)
- [Nginx Performance Tuning](https://www.nginx.com/blog/tuning-nginx/)
