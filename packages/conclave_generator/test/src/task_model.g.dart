// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'task_model.dart';

// **************************************************************************
// DocumentGenerator
// **************************************************************************

// ignore: unused_element
const Map<String, CrdtType> _$TaskSchema = <String, CrdtType>{
  'qty': PnCounter(),
  'tags': OrSet(),
};

// ignore: unused_element
const MergeStrategy _$TaskMergeStrategy = SchemaMergeStrategy(_$TaskSchema);

final Codec<Task> _$TaskCodec = JsonCodec<Task>(
  toMap: _$TaskToMap,
  fromMap: _$TaskFromMap,
  idOf: (Task instance) => instance.id,
);

Map<String, dynamic> _$TaskToMap(Task instance) => <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'done': instance.done,
      'qty': instance.qty,
      'tags': instance.tags,
      'priority': instance.priority,
      'scores': instance.scores,
    };

Task _$TaskFromMap(Map<String, dynamic> map) => Task(
      id: map['id'] as String,
      title: map['title'] as String,
      done: map['done'] as bool? ?? false,
      qty: map['qty'] as num? ?? 0,
      tags: (map['tags'] as List?)?.cast<String>() ?? const [],
      priority: (map['priority'] as num?)?.toInt(),
      scores: (map['scores'] as Map?)
              ?.map((k, v) => MapEntry(k as String, (v as num).toDouble())) ??
          const {},
    );

// ignore: unused_element
const Map<String, CrdtType> _$NoteSchema = <String, CrdtType>{};

// ignore: unused_element
const MergeStrategy _$NoteMergeStrategy = SchemaMergeStrategy(_$NoteSchema);

final Codec<Note> _$NoteCodec = JsonCodec<Note>(
  toMap: _$NoteToMap,
  fromMap: _$NoteFromMap,
  idOf: (Note instance) => instance.id,
);

Map<String, dynamic> _$NoteToMap(Note instance) => <String, dynamic>{
      'id': instance.id,
      'text': instance.text,
    };

Note _$NoteFromMap(Map<String, dynamic> map) => Note(
      map['id'] as String,
      map['text'] as String,
    );
