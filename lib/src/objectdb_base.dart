import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:execution_queue/execution_queue.dart';
import 'package:deeply/deeply.dart';
import 'package:objectdb/src/objectdb_operators.dart';
import 'package:objectdb/src/objectdb_filter.dart';
import 'package:objectdb/src/objectdb_meta.dart';
import 'package:objectdb/src/objectdb_objectid.dart';
import 'package:objectdb/src/objectdb_exceptions.dart';
import 'package:objectdb/src/objectdb_listener.dart';

var keyPathRegExp = RegExp(r"(\w+|\[\w*\])");

class CRUDController {
  static ExecutionQueue _executionQueue;
  ObjectDB db;

  CRUDController(ExecutionQueue queue, {this.db}) {
    // for synchronized database operations
    _executionQueue = queue;
  }

  setDB(ObjectDB db) {
    this.db = db;
  }

  /// get all documents that match [query] with optional change-[listener]
  Future<List<Map<dynamic, dynamic>>> find(Map<dynamic, dynamic> query,
      [ListenerCallback listener]) {
    try {
      if (listener != null) {
        db.listeners.add(Listener(query, listener));
      }
      return _executionQueue
          .add<List<Map<dynamic, dynamic>>>(() => db._find(query));
    } catch (e) {
      rethrow;
    }
  }

  /// get first document that matches [query]
  Future<Map<dynamic, dynamic>> first(Map<dynamic, dynamic> query) {
    try {
      return _executionQueue
          .add<Map<dynamic, dynamic>>(() => db._find(query, Filter.first));
    } catch (e) {
      rethrow;
    }
  }

  /// get last document that matches [query]
  Future<Map<dynamic, dynamic>> last(Map<dynamic, dynamic> query) {
    try {
      return _executionQueue
          .add<Map<dynamic, dynamic>>(() => db._find(query, Filter.last));
    } catch (e) {
      rethrow;
    }
  }

  /// insert document
  Future<ObjectId> insert(Map<dynamic, dynamic> doc) {
    return _executionQueue.add<ObjectId>(() => db._insert(doc));
  }

  /// insert many documents
  Future<List<ObjectId>> insertMany(List<Map<dynamic, dynamic>> docs) {
    return _executionQueue.add<List<ObjectId>>(() {
      List<ObjectId> _ids = [];
      docs.forEach((doc) {
        _ids.add(db._insert(doc));
      });
      return _ids;
    });
  }

  /// remove documents that match [query]
  Future<int> remove(query) {
    // todo: count
    return _executionQueue.add<int>(() => db._remove(query));
  }

  /// update database, takes [query], [changes] and an optional [replace] flag
  Future<int> update(Map<dynamic, dynamic> query, Map<dynamic, dynamic> changes,
      [bool replace = false]) {
    return _executionQueue.add<int>(() => db._update(query, changes, replace));
  }
}

/// Database class
class ObjectDB extends CRUDController {
  // path to file on filesystem
  final String path;
  // database version
  final int v;
  // database file handle
  File _file;
  IOSink _writer;
  // in memory cache
  List<Map<dynamic, dynamic>> _data;
  // queue for synchronized database operations
  static ExecutionQueue _executionQueue = ExecutionQueue();
  // map operator string values to enum values
  Map<String, Op> _operatorMap = Map();
  // database metadata (saved in first line of file)
  Meta _meta = Meta(1, 1);
  CRUDController crudController;
  // default (empty) onUpgrade handler
  Function onUpgrade = (CRUDController db, int oldVersion) async {
    return;
  };

  List<Listener> listeners = List<Listener>();

  ObjectDB(this.path, {this.v = 1, this.onUpgrade}) : super(_executionQueue) {
    this.setDB(this);
    this._file = File(this.path);
    Op.values.forEach((Op op) {
      _operatorMap[op.toString()] = op;
    });
  }

  /// Opens flat file database
  Future<ObjectDB> open([bool cleanup = true]) {
    return _executionQueue
        .add<ObjectDB>(() => this._open(cleanup))
        .catchError((exception) => Future<ObjectDB>.error(exception));
  }

  Future<ObjectDB> _open(bool cleanup) async {
    // restore backup if cleanup failed
    var backupFile = File(this.path + '.bak');
    if (backupFile.existsSync()) {
      if (this._file.existsSync()) {
        this._file.deleteSync();
      }
      backupFile.renameSync(this.path);
      this._file = File(this.path);
    }

    // create database file if not already exist
    if (!this._file.existsSync()) {
      this._file.createSync();
    }
    var reader = this._file.openRead();
    this._data = [];

    int oldVersion;

    bool firstLine = true;
    // read database to in-memory
    await reader
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(LineSplitter())
        .forEach((line) {
      if (line != '') {
        if (firstLine) {
          firstLine = false;
          if (line.startsWith("\$objectdb")) {
            // parse meta information from first line if exists
            try {
              _meta = Meta.fromMap(json.decode(line.substring(9)));
              if (_meta.clientVersion != v) {
                oldVersion = _meta.clientVersion;
                _meta.clientVersion = v;
              }
            } catch (e) {
              // no valid meta -> default meta
            }
            return;
          }
        }
        // add line to in-memory store
        this._fromFile(line);
      }
    });
    if (this._writer != null) await this._writer.close();
    this._writer = this._file.openWrite(mode: FileMode.writeOnlyAppend);

    // call onUpgrade if new version
    if (oldVersion != null) {
      var queue = ExecutionQueue();
      await onUpgrade(CRUDController(queue, db: this), oldVersion);
      // await onUpgrade
      await queue.add<bool>(() => true);
      return await this._cleanup();
    }

    if (cleanup) {
      // do cleanup
      return await this._cleanup();
    }
    return this;
  }

  // do cleanup (resolve updates, inserts and deletes)
  Future<ObjectDB> _cleanup() async {
    await this._writer.close();
    // create backup file
    await this._file.rename(this.path + '.bak');
    this._file = File(this.path);
    IOSink writer = this._file.openWrite();
    // add database meta data to first line
    writer.writeln('\$objectdb' + this._meta.toString());
    // write db entries to file
    writer.writeAll(this._data.map((data) => json.encode(data)), '\n');
    writer.write('\n');
    await writer.flush();
    await writer.close();

    var backupFile = File(this.path + '.bak');
    await backupFile.delete();

    return await this._open(false);
  }

  /// inserts line from file into in-memory store
  void _fromFile(String line) {
    switch (line[0]) {
      // handle insert
      case '+':
        {
          this._insertData(json.decode(line.substring(1)));
          break;
        }
      // handle remove
      case '-':
        {
          this._removeData(this._decode(json.decode(line.substring(1))));
          break;
        }
      // handle update
      case '~':
        {
          var u = json.decode(line.substring(1));
          this._updateData(this._decode(u['q']), this._decode(u['c']), u['r']);
          break;
        }
      // insert entry
      case '{':
        {
          this._insertData(json.decode(line));
          break;
        }
    }
  }

  /// returns matcher for given [query] and optional [op] (recursively)
  Function _match(query, [Op op = Op.and]) {
    bool match(Map<dynamic, dynamic> test) {
      // iterate all query elements
      keyloop:
      for (dynamic i in query.keys) {
        // if element is operator -> create fork-matcher
        if (i is Op) {
          bool match = this._match(query[i], i)(test);
          // if operator is conjunction and match found -> test next
          if (op == Op.and && match) continue;
          // if operator is conjunction and no match found -> data does not match
          if (op == Op.and && !match) return false;

          // if operator is disjunction and no match found -> test next
          if (op == Op.or && !match) continue;
          // if operator is disjunction and matche found -> data does match
          if (op == Op.or && match) return true;

          // if (not-operator and no match) or (not not-operator and match) -> true
          // else -> false
          return Op.not == op ? !match : match;
        }

        // convert objectdb to string
        if (query[i] is ObjectId) {
          query[i] = query[i].toString();
        }

        if (!(i is String))
          throw ObjectDBException("Query key must be string or operator!");

        // split keyPath to array
        var keyPath = keyPathRegExp.allMatches(i);
        dynamic testVal = test;
        for (var keyPathSegment in keyPath) {
          var o = keyPathSegment.group(1);

          if (o == "[]" && testVal is List) {
            var foundMatch = false;
            var subQuery = {i.substring(keyPathSegment.end): query[i]};
            for (var testValElement in testVal) {
              if (_match(subQuery, op)(testValElement)) {
                foundMatch = true;
              }
            }
            if (!foundMatch && op == Op.and) {
              return false;
            } else if (foundMatch && op == Op.or) {
              return true;
            } else {
              return foundMatch;
            }
          }

          if (!(testVal is Map<dynamic, dynamic>) || !testVal.containsKey(o)) {
            if (op != Op.or) {
              return false;
            } else {
              continue keyloop;
            }
          }
          testVal = testVal[o];
        }

        if (op != Op.inList &&
            op != Op.notInList &&
            (!(query[i] is RegExp) && (op != Op.and && op != Op.or)) &&
            testVal.runtimeType != query[i].runtimeType) continue;

        switch (op) {
          case Op.and:
          case Op.not:
            {
              if (query[i] is RegExp) {
                if (!query[i].hasMatch(testVal)) return false;
                break;
              }
              if (testVal != query[i]) return false;
              break;
            }
          case Op.or:
            {
              if (query[i] is RegExp) {
                if (query[i].hasMatch(testVal)) return true;
                break;
              }
              if (testVal == query[i]) return true;
              break;
            }
          case Op.gt:
            {
              if (testVal is String) {
                return testVal.compareTo(query[i]) > 0;
              }
              return testVal > query[i];
            }
          case Op.gte:
            {
              if (testVal is String) {
                return testVal.compareTo(query[i]) >= 0;
              }
              return testVal >= query[i];
            }
          case Op.lt:
            {
              if (testVal is String) {
                return testVal.compareTo(query[i]) < 0;
              }
              return testVal < query[i];
            }
          case Op.lte:
            {
              if (testVal is String) {
                return testVal.compareTo(query[i]) <= 0;
              }
              return testVal <= query[i];
            }
          case Op.ne:
            {
              return testVal != query[i];
            }
          case Op.inList:
            {
              return (query[i] is List) && query[i].contains(testVal);
            }
          case Op.notInList:
            {
              return (query[i] is List) && !query[i].contains(testVal);
            }
          default:
            {}
        }
      }

      return op != Op.and ? false : true;
    }

    return match;
  }

  /// check all listener and notify matches
  void _push(Method method, dynamic data) {
    listeners.forEach((listener) {
      Function match = _match(listener.query);
      switch (method) {
        case Method.add:
          {
            if (match(data)) {
              listener.callback(Method.add, data);
            }
            break;
          }
        case Method.remove:
          {
            listener.callback(Method.remove, data);
            break;
          }
        case Method.update:
          {
            if (match(data)) {
              listener.callback(Method.update, data);
            } else {
              listener.callback(Method.remove, [data['_id']]);
            }
            break;
          }
      }
    });
  }

  /// internal insert
  void _insertData(Map data) {
    if (!data.containsKey('_id')) {
      data['_id'] = ObjectId().toString();
    }
    _push(Method.add, data);
    this._data.add(data);
  }

  /// internal remove
  int _removeData(Map<dynamic, dynamic> query) {
    List match =
        this._data.where(this._match(query)).map((doc) => doc['_id']).toList();
    int count = match.length;
    _push(Method.remove, match);
    this._data.removeWhere(this._match(query));
    return count;
  }

  /// internal update
  int _updateData(Map<dynamic, dynamic> query, Map<dynamic, dynamic> changes,
      bool replace) {
    int count = 0;
    var matcher = this._match(query);
    for (var i = 0; i < this._data.length; i++) {
      if (!matcher(this._data[i])) continue;
      count++;

      if (replace) this._data[i] = Map<dynamic, dynamic>();

      for (var o in changes.keys) {
        if (o is Op) {
          for (String p in changes[o].keys) {
            var keyPath = p.split('.');
            switch (o) {
              case Op.set:
                {
                  this._data[i] = updateDeeply(
                      keyPath, this._data[i], (value) => changes[o][p]);
                  break;
                }
              case Op.unset:
                {
                  if (changes[o][p] == true) {
                    this._data[i] = removeDeeply(keyPath, this._data[i]);
                  }
                  break;
                }
              case Op.max:
                {
                  this._data[i] = updateDeeply(
                      keyPath,
                      this._data[i],
                      (value) => value > changes[o][p] ? changes[o][p] : value,
                      0);
                  break;
                }
              case Op.min:
                {
                  this._data[i] = updateDeeply(
                      keyPath,
                      this._data[i],
                      (value) => value < changes[o][p] ? changes[o][p] : value,
                      0);
                  break;
                }
              case Op.increment:
                {
                  this._data[i] = updateDeeply(keyPath, this._data[i],
                      (value) => value += changes[o][p], 0);
                  break;
                }
              case Op.multiply:
                {
                  this._data[i] = updateDeeply(keyPath, this._data[i],
                      (value) => value *= changes[o][p], 0);
                  break;
                }
              case Op.rename:
                {
                  this._data[i] =
                      renameDeeply(keyPath, changes[o][p], this._data[i]);
                  break;
                }
              default:
                {
                  throw 'invalid';
                }
            }
          }
        } else {
          this._data[i][o] = changes[o];
        }
      }
      _push(Method.update, this._data[i]);
    }

    return count;
  }

  /// Find data in cached database object
  Future _find(query, [Filter filter = Filter.all]) async {
    return Future.sync((() {
      var match = this._match(query);
      if (filter == Filter.all) {
        return this._data.where(match).toList();
      }
      if (filter == Filter.first) {
        return this._data.firstWhere(match, orElse: () => null);
      } else {
        return this._data.lastWhere(match, orElse: () => null);
      }
    }));
  }

  /// Insert [data] update cache object and write change to file
  ObjectId _insert(data) {
    ObjectId _id = ObjectId();
    data['_id'] = _id.toString();
    try {
      this._writer.writeln('+' + json.encode(data));
      this._insertData(data);
    } catch (e) {
      throw ObjectDBException('data contains invalid data types');
    }
    return _id;
  }

  /// Replace operator string to corresponding enum
  Map _decode(Map query) {
    Map prepared = Map();
    for (var i in query.keys) {
      dynamic key = i;
      if (this._operatorMap.containsKey(key)) {
        key = this._operatorMap[key];
      }
      if (query[i] is Map && query[i].containsKey('\$type')) {
        if (query[i]['\$type'] == 'regex') {
          prepared[key] = RegExp(query[i]['pattern']);
        }
        continue;
      }

      if (query[i] is Map) {
        prepared[key] = this._decode(query[i]);
      } else if (query[i] is int ||
          query[i] is double ||
          query[i] is bool ||
          query[i] is String ||
          query[i] is List ||
          query[i] == null) {
        prepared[key] = query[i];
      } else {
        throw ObjectDBException(
            "Query contains invalid data type '${query[i]?.runtimeType}'");
      }
    }
    return prepared;
  }

  /// Replace operator enum to corresponding string
  Map _encode(Map query) {
    Map prepared = Map();
    for (var i in query.keys) {
      dynamic key = i;
      if (key is Op) {
        key = key.toString();
      }

      prepared[key] = this._encodeValue(query[i]);
    }
    return prepared;
  }

  _encodeValue(dynamic value) {
    if (value is Map) {
      return this._encode(value);
    }
    if (value is String ||
        value is int ||
        value is double ||
        value is bool ||
        value is List) {
      return value;
    }
    if (value is RegExp) {
      return {'\$type': 'regex', 'pattern': value.pattern};
    }
  }

  int _remove(Map query) {
    this._writer.writeln('-' + json.encode(this._encode(query)));
    return this._removeData(query);
  }

  int _update(query, changes, replace) {
    this._writer.writeln('~' +
        json.encode({
          'q': this._encode(query),
          'c': this._encode(changes),
          'r': replace
        }));
    return this._updateData(query, changes, replace);
  }

  /// cleanup .db file
  Future<ObjectDB> cleanup() {
    return _executionQueue.add<ObjectDB>(() => this._cleanup());
  }

  /// close db
  Future close() {
    return _executionQueue.add(() async {
      await this._writer.close();
    });
  }
}
