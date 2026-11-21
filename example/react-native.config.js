const path = require('path');
const pkg = require('../package.json');

// Autolink the library from the repository root instead of node_modules.
module.exports = {
  project: {
    ios: { automaticPodsInstallation: true },
  },
  dependencies: {
    [pkg.name]: {
      root: path.join(__dirname, '..'),
    },
  },
};
