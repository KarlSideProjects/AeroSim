extends GutTest

const TraceWriter = preload("res://common/diagnostics/px4_qualification_trace_writer.gd")

var trace_path := "user://px4-qualification-trace-writer-test.json"


func after_each() -> void:
    DirAccess.remove_absolute(trace_path)
    DirAccess.remove_absolute("%s.tmp" % trace_path)


func test_completed_temporary_trace_keeps_the_previous_complete_trace_parseable_until_atomic_replace() -> void:
    var previous := {"generation": "previous", "complete": true}
    var replacement := {"generation": "replacement", "complete": true, "samples": [1, 2, 3]}
    assert_true(TraceWriter.replace_json(trace_path, previous).ok)

    var temporary := FileAccess.open("%s.tmp" % trace_path, FileAccess.WRITE)
    assert_not_null(temporary)
    temporary.store_string(JSON.stringify(replacement))
    temporary.flush()
    temporary.close()

    var before_replace: Variant = JSON.parse_string(FileAccess.get_file_as_string(trace_path))
    assert_eq(before_replace, previous)

    assert_true(TraceWriter.replace_json(trace_path, replacement).ok)
    var after_replace: Variant = JSON.parse_string(FileAccess.get_file_as_string(trace_path))
    assert_true(typeof(after_replace) == TYPE_DICTIONARY)
    assert_eq(after_replace.generation, "replacement")
    assert_true(after_replace.complete)
    assert_eq(after_replace.samples.size(), 3)
