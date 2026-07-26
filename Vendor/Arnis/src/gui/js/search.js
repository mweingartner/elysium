// City Search Functionality
var citySearch = {
    searchTimeout: null,
    activeRequest: null,
    throttleTimeout: null,
    lastRequestAt: 0,
    resultCache: Object.create(null),
    
    init: function() {
        this.bindEvents();
    },
    
    bindEvents: function() {
        var self = this;
        
        // Search on button click
        $('#search-btn').on('click', function() {
            clearTimeout(self.searchTimeout);
            self.performSearch();
        });
        
        // Search on Enter key
        $('#city-search').on('keypress', function(e) {
            if (e.which === 13) { // Enter key
                clearTimeout(self.searchTimeout);
                self.performSearch();
            }
        });
        
        // Public Nominatim explicitly forbids client-side autocomplete. Typing only
        // clears stale results; a request requires Enter or the Search button.
        $('#city-search').on('input', function() {
            clearTimeout(self.searchTimeout);
            self.hideResults();
        });
        
        // Hide results when clicking outside
        $(document).on('click', function(e) {
            if (!$(e.target).closest('#search-container').length) {
                self.hideResults();
            }
        });
    },
    
    performSearch: function(query) {
        var self = this;
        query = query || $('#city-search').val().trim();
        
        if (query.length < 2) {
            return;
        }

        var cacheKey = query.toLocaleLowerCase();
        if (Object.prototype.hasOwnProperty.call(self.resultCache, cacheKey)) {
            self.displayResults(self.resultCache[cacheKey]);
            return;
        }

        // The public Nominatim service permits at most one request per second.
        // Elysium identifies itself in WKWebView's user agent, caches exact searches,
        // and serializes manual/autocomplete requests through the same limiter.
        var delay = 1100 - (Date.now() - self.lastRequestAt);
        if (delay > 0) {
            clearTimeout(self.throttleTimeout);
            self.throttleTimeout = setTimeout(function() {
                self.throttleTimeout = null;
                self.performSearch(query);
            }, delay);
            return;
        }
        
        // Abort any in-flight request so stale responses never overwrite fresh ones
        if (self.activeRequest) {
            self.activeRequest.abort();
            self.activeRequest = null;
        }
        
        this.showLoading();
        
        // Use Nominatim geocoding service
        var url = 'https://nominatim.openstreetmap.org/search';
        var params = {
            q: query,
            format: 'json',
            limit: 5,
            addressdetails: 1,
            extratags: 1,
            'accept-language': 'en'
        };
        
        self.lastRequestAt = Date.now();
        var request = self.activeRequest = $.ajax({
            url: url,
            data: params,
            method: 'GET',
            timeout: 10000,
            success: function(data) {
                if (self.activeRequest !== request) return;
                self.activeRequest = null;
                self.resultCache[cacheKey] = data;
                self.displayResults(data);
            },
            error: function(jqXHR, textStatus) {
                if (self.activeRequest !== request) return;
                self.activeRequest = null;
                if (textStatus !== 'abort') {
                    self.showError('Search failed. Please try again.');
                }
            }
        });
    },
    
    showLoading: function() {
        $('#search-results').html('<div class="search-loading">Searching...</div>').show();
    },
    
    showError: function(message) {
        $('#search-results').html('<div class="search-no-results">' + message + '</div>').show();
    },
    
    hideResults: function() {
        // Abort any in-flight request so a stale response doesn't re-show results
        if (this.activeRequest) {
            this.activeRequest.abort();
            this.activeRequest = null;
        }
        $('#search-results').hide();
    },
    
    displayResults: function(results) {
        var self = this;
        var $results = $('#search-results');
        
        if (results.length === 0) {
            $results.html('<div class="search-no-results">No cities found</div>').show();
            return;
        }
        
        var html = '';
        results.forEach(function(result) {
            var displayName = result.display_name;
            var nameParts = displayName.split(',');
            var mainName = nameParts[0];
            var details = nameParts.slice(1, 3).join(',');
            
            html += '<div class="search-result-item" data-lat="' + result.lat + '" data-lon="' + result.lon + '">';
            html += '<div class="search-result-name">' + self.escapeHtml(mainName) + '</div>';
            html += '<div class="search-result-details">' + self.escapeHtml(details) + '</div>';
            html += '</div>';
        });
        
        $results.html(html).show();
        
        // Bind click events to results
        $('.search-result-item').on('click', function() {
            var lat = parseFloat($(this).data('lat'));
            var lon = parseFloat($(this).data('lon'));
            var name = $(this).find('.search-result-name').text();
            
            self.goToLocation(lat, lon, name);
            self.hideResults();
        });
    },
    
    goToLocation: function(lat, lon, name) {
        if (typeof map !== 'undefined' && map) {
            // Clear existing bbox selection and spawn points
            if (typeof drawnItems !== 'undefined' && drawnItems) {
                drawnItems.clearLayers();
            }
            
            // Try to access bounds through the map layers or find the bounds rectangle
            var boundsLayer = null;
            map.eachLayer(function(layer) {
                if (layer instanceof L.Rectangle && layer.options.color === '#3778d4') {
                    boundsLayer = layer;
                }
            });
            
            if (boundsLayer) {
                boundsLayer.setBounds(new L.LatLngBounds([0.0, 0.0], [0.0, 0.0]));
                
                // Update the bbox display
                if (typeof formatBounds === 'function') {
                    $('#boxbounds').text(formatBounds(boundsLayer.getBounds(), '4326'));
                    
                    if (typeof currentproj !== 'undefined') {
                        $('#boxboundsmerc').text(formatBounds(boundsLayer.getBounds(), currentproj));
                    }
                }
                
                // Notify parent window of bbox update
                if (typeof notifyBboxUpdate === 'function') {
                    notifyBboxUpdate();
                }
            }
            
            // Simply zoom to location without adding markers or popups
            map.setView([lat, lon], 12);
            
            // Clear search box
            $('#city-search').val('');
        }
    },
    
    escapeHtml: function(text) {
        var div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }
};

// Initialize search when document is ready
$(document).ready(function() {
    // Wait a bit for the map to be initialized
    setTimeout(function() {
        if (typeof map !== 'undefined') {
            citySearch.init();
        }
    }, 1000);
});
