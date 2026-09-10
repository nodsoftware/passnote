// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'main.dart';

// **************************************************************************
// DocumentGenerator
// **************************************************************************

// ignore: unused_element
const Map<String, CrdtType> _$ItemSchema = <String, CrdtType>{};

// ignore: unused_element
const MergeStrategy _$ItemMergeStrategy = SchemaMergeStrategy(_$ItemSchema);

final Codec<Item> _$ItemCodec = JsonCodec<Item>(
  toMap: _$ItemToMap,
  fromMap: _$ItemFromMap,
  idOf: (Item instance) => instance.id,
);

Map<String, dynamic> _$ItemToMap(Item instance) => <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'done': instance.done,
    };

Item _$ItemFromMap(Map<String, dynamic> map) => Item(
      id: map['id'] as String,
      name: map['name'] as String,
      done: map['done'] as bool? ?? false,
    );
