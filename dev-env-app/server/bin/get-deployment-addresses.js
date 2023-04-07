const http = require('http')

const { getRequestOptions, responseHandler } = require('./common')

const getDeploymentAddresses = http.request(
  getRequestOptions({
    path: '/get-deployment-addresses',
  }),
  responseHandler,
)

getDeploymentAddresses.write('{}')
getDeploymentAddresses.end()
