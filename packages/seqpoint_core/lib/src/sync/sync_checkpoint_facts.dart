import 'dart:convert';
import '../db/database.dart';
import 'hlc.dart';
import 'operation.dart';

Operation checkpointOperation(Map<String,Object?> row)=>Operation(
  opId:row['op_id'] as String,deviceId:row['device_id'] as String,
  hlc:Hlc(millis:row['hlc_millis'] as int,counter:row['hlc_counter'] as int,deviceId:row['device_id'] as String),
  objectType:row['object_type'] as String,objectId:row['object_id'] as String,
  field:row['field'] as String,value:jsonDecode(row['value_json'] as String));

/// Keep per-author field maxima, including tombstones, restores and unresolved parents.
const checkpointWinnerSql='''SELECT * FROM (
  SELECT *,ROW_NUMBER() OVER(PARTITION BY object_type,object_id,field
    ORDER BY hlc_millis DESC,hlc_counter DESC) AS rank
  FROM sync_operations WHERE device_id=? AND publication_seq<=?
) WHERE rank=1''';

Iterable<Map<String,Object?>> checkpointFacts(SeqDatabase db,String author,int sequence) sync* {
  final buckets=db.raw.select('SELECT DISTINCT substr(object_id,1,2) AS bucket FROM sync_operations '
    'WHERE device_id=? AND publication_seq<=? ORDER BY bucket',[author,sequence]);
  for(final bucket in buckets) {
    var type='',id='',field='';
    while(true) {
      final rows=db.raw.select('$checkpointWinnerSql AND substr(object_id,1,2)=? '
        'AND (object_type,object_id,field)>(?,?,?) ORDER BY object_type,object_id,field LIMIT 100',
        [author,sequence,bucket['bucket'],type,id,field]);
      if(rows.isEmpty) break;
      for(final row in rows) { yield row; }
      type=rows.last['object_type'] as String;id=rows.last['object_id'] as String;field=rows.last['field'] as String;
    }
  }
}
