part of sqljocky;

/**
 * Query is created by ConnectionPool.prepare(sql) and Transaction.prepare(sql). It holds
 * a prepared query. Set parameters on it using the square bracket operators.
 */
class Query {
  final ConnectionPool _pool;
  final _Connection _cnx;
  final String sql;
  final Logger log;
  final _inTransaction;
  List<dynamic> _values;
  bool _executed = false;
  
  Query._internal(this._pool, this.sql) :
      _cnx = null,
      _inTransaction = false,
      log = new Logger("Query");

  Query._forTransaction(this._pool, _Connection cnx, this.sql) :
      _cnx = cnx,
      _inTransaction = true,
      log = new Logger("Query");
  
  Future<_Connection> _getConnection() {
    if (_cnx != null) {
      var c = new Completer<_Connection>();
      c.complete(_cnx);
      return c.future;
    }
    return _pool._getConnection();
  }

  Future<_PreparedQuery> _prepare() {
    log.fine("Getting prepared query for: $sql");
    var c = new Completer<_PreparedQuery>();
    
    _getConnection()
      .then((cnx) {
        log.fine("Got cnx#${cnx.number}");
        if (!_useCachedQuery(cnx, c)) {
          _prepareAndCacheQuery(cnx, c);
        }
      })
      .catchError((e) {
        c.completeError(e);
      });
    return c.future;
  }
  
  /**
   * Returns true if there was already a cached query which has been used.
   */
  bool _useCachedQuery(_Connection cnx, Completer c) {
    var preparedQuery = cnx.getPreparedQueryFromCache(sql);
    if (preparedQuery == null) {
      return false;
    }

    log.fine("Got prepared query from cache in cnx#${cnx.number} for: $sql");
    _setUpValues(preparedQuery);
    c.complete(preparedQuery);
    return true;
  }
  
  void _prepareAndCacheQuery(_Connection cnx, Completer c) {
    log.fine("Preparing new query in cnx#${cnx.number} for: $sql");
    var handler = new _PrepareHandler(sql);
    cnx.use();
    cnx.processHandler(handler)
      .then((preparedQuery) {
        log.fine("Prepared new query in cnx#${cnx.number} for: $sql");
        preparedQuery.cnx = cnx;
        cnx.putPreparedQueryInCache(sql, preparedQuery);
        _setUpValues(preparedQuery);
        c.complete(preparedQuery);
      })
      .catchError((e) {
        c.completeError(e);
        _releaseConnection(cnx);
        _reuseConnection(cnx);
      });
  }
  
  _setUpValues(_PreparedQuery preparedQuery) {
    if (_values == null) {
      _values = new List<dynamic>(preparedQuery.parameters.length);
    }
  }
      
  void close() {
    _pool._closeQuery(this, _inTransaction);
  }
  
  //TODO: maybe have execute(Transaction) and execute(ConnectionPool)/**
  /**
   * Executes the query, returning a future [Results] object.
   */
  Future<Results> execute() {
    var c = new Completer<Results>();
    _prepare()
      .then((preparedQuery) {
        _execute(preparedQuery)
          .then((Results results) {
            if (results.stream != null) {
              //TODO can the result transform itself?
              (results as _ResultsImpl).onDone = () {
                _releaseConnection(preparedQuery.cnx);
                _reuseConnection(preparedQuery.cnx);
              };
              c.complete(results);
            } else {
              _releaseConnection(preparedQuery.cnx);
              c.complete(results);
              _reuseConnection(preparedQuery.cnx);
            }
          })
          .catchError((e) {
            c.completeError(e);
          });
      })
      .catchError((e) {
        c.completeError(e);
      });
    return c.future;
  }
  
  Future<Results> _execute(_PreparedQuery preparedQuery) {
    log.finest("About to execute");
    var c = new Completer<Results>();
    var handler = new _ExecuteQueryHandler(preparedQuery, _executed, _values);
    preparedQuery.cnx.processHandler(handler)
      .then((results) {
        log.finest("Prepared query got results");
        c.complete(results);
      })
      .catchError((e) {
        c.completeError(e);
        _releaseConnection(preparedQuery.cnx);
        _reuseConnection(preparedQuery.cnx);
      });
    return c.future;
  }

  /**
   * Executes the query once for each set of [parameters], and returns a future list
   * of results, one for each set of parameters, that completes when the query has been executed.
   *
   * The [Results] in the list contain their rows in the [Results.rows] field, rather than in the
   * [Results.stream] field.
   */
  Future<List<Results>> executeMulti(List<List<dynamic>> parameters) {
    var c = new Completer<List<Results>>();
    _prepare()
      .then((preparedQuery) {
        log.fine("Prepared query for multi execution. Number of values: ${parameters.length}");
        var resultList = new List<Results>();
        
        executeQuery(int i) {
          log.fine("Executing query, loop $i");
          _values.setRange(0, _values.length, parameters[i]);
          _execute(preparedQuery)
            .then((Results results) {
              if (results.stream != null) {
                results.toResultsList().then((newResults) {
                  log.fine("Got results, loop $i");
                  resultList.add(newResults);
                  if (i < parameters.length - 1) {
                    executeQuery(i + 1);
                  } else {
                    _releaseConnection(preparedQuery.cnx);
                    c.complete(resultList);
                    _reuseConnection(preparedQuery.cnx);
                  }
                });
              } else {
                log.fine("Got results, loop $i");
                resultList.add(results);
                if (i < parameters.length - 1) {
                  executeQuery(i + 1);
                } else {
                  _releaseConnection(preparedQuery.cnx);
                  c.complete(resultList);
                  _reuseConnection(preparedQuery.cnx);
                }
              }
            })
            .catchError((e) {
              c.completeError(e);
              _releaseConnection(preparedQuery.cnx);
              _reuseConnection(preparedQuery.cnx);
            });
        }
        
        executeQuery(0);
      })
      .catchError((e) {
        c.completeError(e);
      });
    return c.future;
  }

  /**
   * Get a current parameter value.
   */
  dynamic operator [](int pos) => _values[pos];

  /**
   * Set a parameter value.
   */
  void operator []=(int index, dynamic value) {
    _values[index] = value;
    _executed = false;
  }

  _releaseConnection(_Connection cnx) {
    if (!_inTransaction) {
      _pool._releaseConnection(cnx);
    }
  }

  /**
   * Attempt to reuse a connection for a queued operation
   */
  _reuseConnection(_Connection cnx) {
    if (!_inTransaction) {
      _pool._reuseConnection(cnx);
    }
  }
//  dynamic longData(int index, data);
//  dynamic reset();
//  dynamic fetch(int rows);
}
