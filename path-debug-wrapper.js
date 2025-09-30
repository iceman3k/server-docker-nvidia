const originalPathDirname = require('path').dirname;
require('path').dirname = function(path) {
    console.log('Intercepted path.dirname call.');
    console.log('  Argument type:', typeof path);
    console.log('  Argument value:', path);
    if (typeof path !== 'string') {
        console.log('  Argument is not a string, returning current working directory.');
        return process.cwd();
    }
    const result = originalPathDirname(path);
    console.log('  Returning:', result);
    return result;
};

require('./server.js');
