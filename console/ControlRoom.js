angular.module('ControlRoom', ['ngRoute', 'ngResource', 'checklist-model'])

.factory('Pipeline', ['$resource', function($resource) {
    return $resource('/pipeline/:name', {}, {
        list: {
            method: 'GET',
            url: '/pipelines',
            isArray: true
        },
        run: {
            method: 'POST',
            url: '/pipeline/:name/run',
        }
    });
}])

.config(['$routeProvider', '$locationProvider', function($routeProvider, $locationProvider) {
    $routeProvider
    .when('/', {
        templateUrl: '/static/home.html'
    })
    .when('/pipeline/:name', {
        controller: 'Pipeline',
        templateUrl: '/static/pipeline.html'
    })
    .otherwise({
        redirectTo: '/'
    });

    // Don't use location.hash (anchors, #) if at all possible
    $locationProvider.html5Mode(true);
}])

.config(['$httpProvider', function ($httpProvider) {
    // Intercept POST requests, convert to standard form encoding
    $httpProvider.defaults.headers.post["Content-Type"] = "application/x-www-form-urlencoded";
    $httpProvider.defaults.transformRequest.unshift(function(data, getHeaders) {
        if (!angular.isObject(data))
            return data;
        return Object.keys(data)
            .map(function(k){
                var pairs = angular.isArray(data[k])
                    ? data[k].map(function(v){ return [ k, v ] })
                    : [ [k, data[k]] ];

                return pairs.map(function(p){
                    return p.join("=")
                }).join("&")
            }).join("&");
    });
}])

.controller('Main', ['$scope', 'Pipeline', function($scope, Pipeline) {
    Pipeline.list(function(_){ $scope.pipelines = _ });
}])

.controller('Pipeline', ['$scope', '$routeParams', 'Pipeline', function($scope, $routeParams, Pipeline) {
    $scope.pipeline = Pipeline.get({ name: $routeParams.name });
}])

.controller('Pipeline.RunTargets', ['$scope', 'Pipeline', '$log', function($scope, Pipeline, $log) {
    $scope.selected = [];
    $scope.submit   = function(){
        Pipeline.run(
            { name: $scope.pipeline.name },
            { targets: $scope.selected }
        ).$promise.then(function(results) {
            $scope.results = results;
        });
    };
}])

;
