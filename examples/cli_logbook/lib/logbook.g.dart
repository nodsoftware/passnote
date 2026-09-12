// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'logbook.dart';

// **************************************************************************
// DocumentGenerator
// **************************************************************************

// ignore: unused_element
const Map<String, CrdtType> _$EntrySchema = <String, CrdtType>{
  'stars': PnCounter(),
};

// ignore: unused_element
const MergeStrategy _$EntryMergeStrategy = SchemaMergeStrategy(_$EntrySchema);

final Codec<Entry> _$EntryCodec = JsonCodec<Entry>(
  toMap: _$EntryToMap,
  fromMap: _$EntryFromMap,
  idOf: (Entry instance) => instance.id,
);

Map<String, dynamic> _$EntryToMap(Entry instance) => <String, dynamic>{
      'id': instance.id,
      'text': instance.text,
      'stars': instance.stars,
    };

Entry _$EntryFromMap(Map<String, dynamic> map) => Entry(
      id: map['id'] as String,
      text: map['text'] as String,
      stars: map['stars'] as num? ?? 0,
    );
