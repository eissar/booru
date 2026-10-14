package importers

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:time"

Iso_Time :: distinct string

iso_time_unmarshaler :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	if p.curr_token.kind != .Integer {return .Invalid_Data}
	ms, ok := strconv.parse_i64(p.curr_token.text)
	if !ok {return .Invalid_Data}
	dt, _ := time.time_to_datetime(time.Time{_nsec = ms * 1_000_000})
	(^Iso_Time)(v.data)^ = Iso_Time(
		fmt.aprintf(
			"%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
			dt.year,
			dt.month,
			dt.day,
			dt.hour,
			dt.minute,
			dt.second,
			ms % 1000,
			allocator = p.allocator,
		),
	)
	json.advance_token(p)
	return nil
}
@(init)
register_unmarshalers :: proc "contextless" () {
	context = runtime.default_context()
	json.set_user_unmarshalers(new(map[typeid]json.User_Unmarshaler))
	json.register_user_unmarshaler(Iso_Time, iso_time_unmarshaler)
}
