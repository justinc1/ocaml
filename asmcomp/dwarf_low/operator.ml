(***********************************************************************)
(*                                                                     *)
(*                               OCaml                                 *)
(*                                                                     *)
(*                 Mark Shinwell, Jane Street Europe                   *)
(*                                                                     *)
(*  Copyright 2013--2015, Jane Street Holding                          *)
(*                                                                     *)
(*  Licensed under the Apache License, Version 2.0 (the "License");    *)
(*  you may not use this file except in compliance with the License.   *)
(*  You may obtain a copy of the License at                            *)
(*                                                                     *)
(*      http://www.apache.org/licenses/LICENSE-2.0                     *)
(*                                                                     *)
(*  Unless required by applicable law or agreed to in writing,         *)
(*  software distributed under the License is distributed on an        *)
(*  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,       *)
(*  either express or implied.  See the License for the specific       *)
(*  language governing permissions and limitations under the License.  *)
(*                                                                     *)
(***********************************************************************)

type t =
  | DW_op_addr of Value.t
  | DW_op_regx of Value.t
  | DW_op_fbreg of Value.t
  | DW_op_bregx of [ `Register of Value.t ] * [ `Offset of Value.t ]

let at_offset_from_symbol ~base:_ ~symbol ~offset_in_bytes =
  let value =
    Value.as_code_address_from_label_diff
      (`Symbol_plus_offset_in_bytes (symbol, offset_in_bytes))
      (`Symbol "0")
  in
  DW_op_addr value

let register ~reg_number =
  let reg_number = Value.as_uleb128 reg_number in
  DW_op_regx reg_number

let register_based_addressing ~reg_number ~offset_in_bytes =
  let reg_number = Value.as_uleb128 reg_number in
  let offset_in_bytes = Value.as_leb128 offset_in_bytes in
  DW_op_bregx (`Register reg_number, `Offset offset_in_bytes)

let frame_base_register ~offset_in_bytes =
  let offset_in_bytes = Value.as_leb128 offset_in_bytes in
  DW_op_fbreg offset_in_bytes

(* DWARF-4 spec section 7.7.1. *)
let opcode = function
  | DW_op_addr _ -> 0x03
  | DW_op_regx _ -> 0x90
  | DW_op_fbreg _ -> 0x91
  | DW_op_bregx _ -> 0x92

let size t =
  let opcode_size = Int64.of_int 1 in
  let args_size =
    match t with
    | DW_op_addr addr -> Value.size addr
    | DW_op_regx reg_number -> Value.size reg_number
    | DW_op_fbreg offset -> Value.size offset
    | DW_op_bregx (`Register reg_number, `Offset offset) ->
      Int64.add (Value.size reg_number) (Value.size offset)
  in
  Int64.add opcode_size args_size

let emit t ~emitter =
  Value.emit (Value.as_byte (opcode t)) ~emitter;
  match t with
  | DW_op_addr addr -> Value.emit addr ~emitter
  | DW_op_regx reg_number -> Value.emit reg_number ~emitter
  | DW_op_fbreg offset -> Value.emit offset ~emitter
  | DW_op_bregx (`Register reg_number, `Offset offset) ->
    Value.emit reg_number ~emitter;
    Value.emit offset ~emitter
