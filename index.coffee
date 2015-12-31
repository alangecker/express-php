url = require "url"
path = require "path"
fs = require "fs"
child = require 'child_process'


module.exports =
  cgi: (phproot, cmd) -> (req, res, next) =>
      req.pause()
      @decideFile req.url, phproot, (file) =>
        if file
          @run(file, req, res, cmd)
        else
          next()


  decideFile: (reqUrl, phpdir, callback) ->
    # TODO: maybe cache this method results?
    parts = url.parse(reqUrl)
    parts.pathInfo = ''
    folders = parts.pathname.split('/')
    isPhpFile = false

    parts.pathname = '/'
    for folder in folders
      parts.pathname = path.join(parts.pathname, folder) if(!isPhpFile)
      if isPhpFile
        parts.pathInfo += '/'+folder
      else if /.*?\.php$/.test(folder)
        isPhpFile = true


    file = path.join(phpdir, parts.pathname)
    return callback(false) if not isPhpFile && file.substr(-1,1) != '/'

    fs.stat file, (err, stats) ->
      return callback(false) if err
      if stats.isDirectory()
        file = path.join(file, "index.php")
      else if not isPhpFile
        return callback(false)
      callback(
        path: file
        scriptName: parts.pathname
        pathInfo: parts.pathInfo
        query: parts.query
      )

  getEnvironment: (file, req) ->
    # by Martin K. Schröder (https://github.com/mkschreder/node-php)
    env =
      SERVER_SIGNATURE: "NodeJS server at localhost"
      PATH_INFO: file.pathInfo #The extra path information, as given in the requested URL. In fact, scripts can be accessed by their virtual path, followed by extra information at the end of this path. The extra information is sent in PATH_INFO.
      PATH_TRANSLATED: "" #The virtual-to-real mapped version of PATH_INFO.
      SCRIPT_NAME: file.scriptName #The virtual path of the script being executed.
      SCRIPT_FILENAME: file.path,
      REQUEST_FILENAME: file.path #The real path of the script being executed.
      SCRIPT_URI: req.url #The full URL to the current object requested by the client.
      URL: req.url #The full URI of the current request. It is made of the concatenation of SCRIPT_NAME and PATH_INFO (if available.)
      SCRIPT_URL: req.url,
      REQUEST_URI: req.url #The original request URI sent by the client.
      REQUEST_METHOD: req.method #The method used by the current request; usually set to GET or POST.
      QUERY_STRING: file.query||"" #The information which follows the ? character in the requested URL.
      CONTENT_TYPE: req.get("Content-type")||"" #"multipart/form-data" #"application/x-www-form-urlencoded", #The MIME type of the request body; set only for POST or PUT requests.
      CONTENT_LENGTH: req.get("Content-Length")||0
      AUTH_TYPE: "" #The authentication type if the client has authenticated itself to access the script.
      AUTH_USER: ""
      REMOTE_USER: "" #The name of the user as issued by the client when authenticating itself to access the script.
      ALL_HTTP: Object.keys(req.headers).map((x)->"HTTP_#{x.toUpperCase().replace("-", "_")}: "+req.headers[x]).reduce(((a, b)->a+b+"\n"), "") #All HTTP headers sent by the client. Headers are separated by carriage return characters (ASCII 13 - \n) and each header name is prefixed by HTTP_, transformed to upper cases, and - characters it contains are replaced by _ characters.
      ALL_RAW: Object.keys(req.headers).map((x)->x+": "+req.headers[x]).reduce(((a, b)->a+b+"\n"), "") #All HTTP headers as sent by the client in raw form. No transformation on the header names is applied.
      SERVER_SOFTWARE: "NodeJS" #The web server's software identity.
      SERVER_NAME: "localhost" #The host name or the IP address of the computer running the web server as given in the requested URL.
      SERVER_ADDR: "127.0.0.1" #The IP address of the computer running the web server.
      SERVER_PORT: 8011 #The port to which the request was sent.
      GATEWAY_INTERFACE: "CGI/1.1" #The CGI Specification version supported by the web server; always set to CGI/1.1.
      SERVER_PROTOCOL: "" #The HTTP protocol version used by the current request.
      REMOTE_ADDR: req.headers['x-forwarded-for'] || req.connection.remoteAddress #The IP address of the computer that sent the request.
      REMOTE_PORT: "" #The port from which the request was sent.
      DOCUMENT_ROOT: "" #The absolute path of the web site files. It has the same value as Documents Path.
      INSTANCE_ID: "" #The numerical identifier of the host which served the request. On Abyss Web Server X1, it is always set to 1 since there is only a single host.
      APPL_MD_PATH: "" #The virtual path of the deepest alias which contains the request URI. If no alias contains the request URI, the variable is set to /.
      APPL_PHYSICAL_PATH: "" #The real path of the deepest alias which contains the request URI. If no alias contains the request URI, the variable is set to the same value as DOCUMENT_ROOT.
      IS_SUBREQ: "" #It is set to true if the current request is a subrequest, i.e. a request not directly invoked by a client. Otherwise, it is set to true. Subrequests are generated by the server for internal processing. XSSI includes for example result in subrequests.
      REDIRECT_STATUS: 1

    Object.keys(req.headers).map (x)-> env["HTTP_"+x.toUpperCase().replace("-", "_")] = req.headers[x]

    return env


  run: (file, req, res, cm) ->

    err = ""
    cmd = cmd || "php-cgi"
    php = child.spawn(cmd, [], {env: @getEnvironment(file, req)})
    php.stdout.pause()
    req.pipe(php.stdin)
    req.resume()

    buf = []
    headerSent = false
    php.stdout.on "data", (data) ->
      if headerSent
        buf.push data
      else
        chunk = data.toString('binary')
        body = chunk.split("\r\n\r\n")
        if body.length > 1
          head = body[0].split("\r\n")
          for header in head
            h = header.split(": ")
            res.statusCode = parseInt(h[1]) if h[0] == "Status"
            res.setHeader(h[0], h[1]) if h.length == 2
          headerSent = true
          buf.push data.slice(body[0].length+4)
        else
          buf.push data

    php.stdout.on "end", (code) ->
      php.stdin.end()
      res.status(res.statusCode).send(Buffer.concat(buf))
      res.end()
    php.on "error", (err) -> console.error(err)
    php.stdout.resume()
