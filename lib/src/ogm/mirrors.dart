part of neo4j_dart.ogm;

const _defaultConstructor = const Symbol('');
final _objects = new Expando();
final _hasRelation = new Expando();

final _Relation = reflectType(Relation);
final _DateTime = reflectType(DateTime);
final _String = reflectType(String);
final _bool = reflectType(bool);
final _num = reflectType(num);
final _Iterable = reflectType(Iterable);

String _findLabel(DeclarationMirror cm) => MirrorSystem.getName(cm.simpleName);

bool _isSimpleType(object) {
  if (object is! TypeMirror) {
    object = reflectType(object.runtimeType);
  }

  return object.isAssignableTo(_String) ||
         object.isAssignableTo(_num) ||
         object.isAssignableTo(_bool) ||
         object.isAssignableTo(_DateTime);
}

Map<Symbol, DeclarationMirror> _getDeclarations(ClassMirror cm) {
  if (cm.superclass == null) {
    return const {};
  }

  return {}
    ..addAll(cm.declarations)
    ..addAll(_getDeclarations(cm.superclass));
}

bool _isAssignableTo(ClassMirror value, TypeMirror field) =>
  value.isAssignableTo(field) ||
  (
      (
          value.isSubtypeOf(field.originalDeclaration) ||
          value.superinterfaces.any((cm) => cm.simpleName == field.simpleName) ||
          (value.superclass.mixin.simpleName == #ListBase && field.isSubtypeOf(reflectType(List)))
      ) &&
      field.typeArguments.isNotEmpty && value.typeArguments.isEmpty
  );

bool _canSetType(Map<Symbol, DeclarationMirror> declarations, Symbol field, Type type) {
  var tm = reflectClass(type);

  if (!declarations.containsKey(field) ||
      (declarations[field] is MethodMirror && declarations[field].isGetter)) {
    field = new Symbol(MirrorSystem.getName(field) + '=');
  }
  if (!declarations.containsKey(field)) {
    return false;
  }
  var dm = declarations[field];

  return !dm.isPrivate && !dm.isStatic && (
      (dm is VariableMirror && !dm.isConst && !dm.isFinal && _isAssignableTo(tm, dm.type)) ||
      (dm is MethodMirror && dm.isSetter && _isAssignableTo(tm, dm.parameters.first.type))
  );
}

void _instantiateObject(Map objects, ClassMirror cm, Map properties, int id) {
  if (!objects.containsKey(id)) {
    if (properties.containsKey('@class') && properties.containsKey('@library')) {
      var library = currentMirrorSystem().findLibrary(MirrorSystem.getSymbol(properties['@library']));
      cm = library.declarations[MirrorSystem.getSymbol(properties['@class'])];
    }

    var object = cm.newInstance(_defaultConstructor, []);
    var declarations = _getDeclarations(cm);

    properties.forEach((property, value) {
      var field = new Symbol(property);

      if (value is List && value.isNotEmpty && value.first is int &&
          _canSetType(declarations, field, <DateTime>[].runtimeType)) {
        object.setField(field, value.map((date) =>
          new DateTime.fromMillisecondsSinceEpoch(date, isUtc: true)).toList()
        );
      } else if (_canSetType(declarations, field, value.runtimeType)) {
        object.setField(field, value);
      } else if (value is int && _canSetType(declarations, field, DateTime)) {
        object.setField(field, new DateTime.fromMillisecondsSinceEpoch(value, isUtc: true));
      }
    });

    _setId(object.reflectee, id, cm);
    objects[id] = object;
  }
}

bool _isEdgeField(DeclarationMirror dm) {
  TypeMirror field;
  if (dm is VariableMirror) {
    field = dm.type;
  } else if (dm is MethodMirror && dm.isGetter) {
    field = dm.returnType;
  }

  if (_isAssignableTo(_Iterable, field)) {
    field = field.typeArguments.first;
  }
  if (field.isAssignableTo(_Relation)) {
    return true;
  }

  return false;
}

Object _findOtherObject(Map objects, Map properties, Object start, Symbol field, Symbol edgeField,
                        int otherId) {
  ClassMirror otherClass;
  var startField = start.type.declarations[field];
  if (startField is VariableMirror) {
    otherClass = startField.type;
  } else if (startField is MethodMirror && startField.isGetter) {
    otherClass = startField.returnType;
  }
  if (otherClass.isAssignableTo(_Iterable)) {
    otherClass = otherClass.typeArguments.first;
  }
  if (otherClass.isAssignableTo(_Relation)) {
    otherClass = otherClass.superclass.declarations[edgeField].type;
  }
  _instantiateObject(objects, otherClass, properties, otherId);
  return objects[otherId];
}

bool _isReverseRelation(DeclarationMirror dm, [Symbol to]) =>
  dm.metadata.any((annotation) =>
    annotation.type.simpleName == #ReverseOf &&
    (to == null || annotation.reflectee.field == to)
  );

void _keepRelation(Object object, Symbol field, int edgeId, [int entityId]) {
  if (_hasRelation[object] == null) {
    _hasRelation[object] = [{#field: field, #id: edgeId, #entity: entityId}];
  } else {
    _hasRelation[object].add({#field: field, #id: edgeId, #entity: entityId});
  }
}

void _addToCollection(InstanceMirror object, Symbol field, item) {
  if (object.getField(field).reflectee == null) {
    object.setField(field, [item]);
  } else {
    object.getField(field).reflectee.add(item);
  }
}

_instantiateGraph(Map<int, InstanceMirror> objects, ClassMirror cm, Map<String, Map<String, List<Map>>> graph) {
  var notInstantiated = {};

  for (Map node in graph['nodes']) {
    node['id'] = int.parse(node['id']);
    var className = MirrorSystem.getName(cm.simpleName);

    if (node['labels'].contains(className)) {
      _instantiateObject(objects, cm, node['properties'], node['id']);
    } else {
      notInstantiated[node['id']] = node['properties'];
    }
  }

  for (Map relation in graph['relationships']) {
    var startId = int.parse(relation['startNode']);
    var edgeId = int.parse(relation['id']);
    var endId = int.parse(relation['endNode']);

    InstanceMirror start = objects[startId];
    InstanceMirror end = objects[endId];

    Map<Symbol, DeclarationMirror> startDeclarations;

    var startFieldName = new Symbol(relation['type']);
    var endFieldName;

    if (end == null) {
      end = _findOtherObject(objects, notInstantiated[endId], start, startFieldName, #end, endId);
    }

    try {
      endFieldName = end.type.declarations.values.firstWhere((dm) =>
        _isReverseRelation(dm, startFieldName)).simpleName;

      if (start == null) {
        start = _findOtherObject(
            objects, notInstantiated[startId], end, endFieldName, #start, startId
        );
      }
    } on StateError catch(e) {}

    startDeclarations = _getDeclarations(start.type);

    if (_isEdgeField(startDeclarations[startFieldName])) {
      _keepRelation(start.reflectee, startFieldName, edgeId);

      var edge;
      if (_canSetType(startDeclarations, startFieldName, List)) {
        _instantiateObject(
            objects, startDeclarations[startFieldName].type.typeArguments.first, relation['properties'], edgeId
        );
        edge = objects[edgeId];
        _addToCollection(start, startFieldName, edge.reflectee);
      } else {
        _instantiateObject(
            objects, startDeclarations[startFieldName].type, relation['properties'], edgeId
        );
        edge = objects[edgeId];
        start.setField(startFieldName, edge.reflectee);
      }
      edge.setField(#start, start.reflectee);
      edge.setField(#end, end.reflectee);

      start = edge;
    } else {
      _keepRelation(start.reflectee, startFieldName, edgeId, entityId(end.reflectee));

      if (_canSetType(startDeclarations, startFieldName, List)) {
        _addToCollection(start, startFieldName, end.reflectee);
      } else {
        start.setField(startFieldName, end.reflectee);
      }
    }

    if (endFieldName != null) {
      if (_canSetType(_getDeclarations(end.type), endFieldName, List)) {
        _addToCollection(end, endFieldName, start.reflectee);
      } else {
        end.setField(endFieldName, start.reflectee);
      }

      _keepRelation(end.reflectee, endFieldName, edgeId, entityId(start.reflectee));
    }
  }
}

_instantiate(ClassMirror cm) => (Map result) {
  var objects = {};
  var hasRow = false;

  for (var row in result['data']) {
    if (row.containsKey('row')) {
      hasRow = true;
    }
    if (row.containsKey('graph')) {
      _instantiateGraph(objects, cm, row['graph']);
    } else if (row.containsKey('row')) {
      row = row['row'];
      _instantiateObject(objects, cm, row[1], row[0]);
    } else {
      throw 'Result must contain graph or row data';
    }
  }

  if (hasRow) {
    return result['data']
      .where((row) => row.containsKey('row') && objects.containsKey(row['row'][0]))
      .map((row) {
        var object = objects[row['row'][0]].reflectee;
        objects.remove(row['row'][0]);
        return object;
      })
      .toList();
  }

  return objects.values.map((object) => object.reflectee);
};

Iterable<DeclarationMirror> _getReadableFields(ClassMirror cm) =>
  _getDeclarations(cm).values.where((dm) =>
    dm.simpleName != #id && dm.simpleName != #label && !dm.isPrivate && (
        (dm is VariableMirror && !dm.isStatic) ||
        (dm is MethodMirror && dm.isGetter)
    ));

Map _getProperties(object) {
  var properties = {};
  var cm = reflectClass(object.runtimeType);
  var im = reflect(object);

  for (var dm in _getReadableFields(cm)) {
    var object = im.getField(dm.simpleName).reflectee;

    if (object != null && _isSimpleType(object) ||
        (
            object is Iterable &&
            (object.isEmpty || (object.isNotEmpty && _isSimpleType(object.first)))
        )) {
      if (object is DateTime) {
        object = object.toUtc().millisecondsSinceEpoch;
      } else if (object is Iterable && object.isNotEmpty && object.first is DateTime) {
        object = object.map((date) => date.toUtc().millisecondsSinceEpoch).toList();
      }
      properties[_findLabel(dm)] = object;
    }
  }

  properties['@library'] = MirrorSystem.getName(cm.owner.simpleName);
  properties['@class'] = MirrorSystem.getName(cm.simpleName);

  return properties;
}

TypeMirror _collectionType(DeclarationMirror dm) {
  TypeMirror type;
  if (dm is VariableMirror) {
    type = dm.type;
  } else if (dm is MethodMirror && dm.isGetter) {
    type = dm.returnType;
  }
  if (type.typeArguments.isEmpty) {
    return reflectType(Object);
  }

  return type.typeArguments.first;
}


Iterable<Relation> _getEdges(ClassMirror cm, start) {
  var im = reflect(start);

  var relations = _getReadableFields(cm).where((dm) {
    var object = im.getField(dm.simpleName).reflectee;

    return object != null && !_isSimpleType(object) && !(object is List && _isSimpleType(_collectionType(dm)));
  });

  var edges = relations
    .where(_isEdgeField)
    .expand((dm) {
      var object = im.getField(dm.simpleName).reflectee;
      if (object is Iterable) {
        return object.map((edge) => edge
          ..start = start
          .._label = _findLabel(dm));
      } else {
        return [object
          ..start = start
          .._label = _findLabel(dm)
        ];
      }
    })
    .toList();

  edges.addAll(relations
    .where((dm) => !_isEdgeField(dm) &&
                   !_isReverseRelation(dm))
    .expand((dm) {
      var object = im.getField(dm.simpleName).reflectee;
      if (object is Iterable) {
        return object
          .map(((end) => new Relation()
            ..start = start
            ..end = end
            .._label = _findLabel(dm))
          )
          .toList();
      } else {
        return [
          new Relation()
            ..start = start
            ..end = object
            .._label = _findLabel(dm)
        ];
      }
    })
    .toList());

  return edges;
}

Iterable<int> _removedRelations(Object object) {
  if (_hasRelation[object] == null) {
    return const [];
  }
  var im = reflect(object);

  return _hasRelation[object]
    .where((relation) {
      var value = im.getField(relation[#field]).reflectee;

      if (value is Iterable) {
        return value.every((edge) {
          if (edge is Relation) {
            return entityId(edge) != relation[#id];
          }
          return entityId(edge) != relation[#entity];
        });
      }

      return value == null;
    })
    .map((relation) => relation[#id]);
}

_setId(Object object, int id, [ClassMirror cm]) {
  _objects[object] = id;

  if (cm == null) {
    cm = reflectClass(object.runtimeType);
  }

  // If the object contains an id variable or setter it's set to the database id
  if (_canSetType(_getDeclarations(cm), #id, int)) {
    object.id = id;
  }
}

/// Gets the database id of [entity] if it exist, or null otherwise
int entityId(entity) => _objects[entity];
