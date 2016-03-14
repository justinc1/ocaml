(***********************************************************************)
(*                                                                     *)
(*                               OCaml                                 *)
(*                                                                     *)
(*                 Mark Shinwell, Jane Street Europe                   *)
(*                                                                     *)
(*  Copyright 2016 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the GNU Library General Public License, with    *)
(*  the special exception on linking described in file ../LICENSE.     *)
(*                                                                     *)
(***********************************************************************)

module Gc_stats : sig
  type t

  val minor_words : t -> int
  val promoted_words : t -> int
  val major_words : t -> int
  val minor_collections : t -> int
  val major_collections : t -> int
  val heap_words : t -> int
  val heap_chunks : t -> int
  val compactions : t -> int
  val top_heap_words : t -> int
end = struct
  type t = {
    minor_words : int;
    promoted_words : int;
    major_words : int;
    minor_collections : int;
    major_collections : int;
    heap_words : int;
    heap_chunks : int;
    compactions : int;
    top_heap_words : int;
  }

  let minor_words t = t.minor_words
  let promoted_words t = t.promoted_words
  let major_words t = t.major_words
  let minor_collections t = t.minor_collections
  let major_collections t = t.major_collections
  let heap_words t = t.heap_words
  let heap_chunks t = t.heap_chunks
  let compactions t = t.compactions
  let top_heap_words t = t.top_heap_words
end

module Program_counter = struct
  module OCaml = struct
    type t = Int64.t

    let to_int64 t = t
  end

  module Foreign = struct
    type t = Int64.t

    let to_int64 t = t
  end
end

module Function_identifier = struct
  type t = Int64.t

  let to_int64 t = t
end

module Function_entry_point = struct
  type t = Int64.t

  let to_int64 t = t
end

module Frame_table = struct
  type t = (Program_counter.OCaml.t, Printexc.Slot.t) Hashtbl.t

  let find_exn = Hashtbl.find
end

module Annotation = struct
  type t = int

  external lowest_allowable : unit -> t
    = "caml_allocation_profiling_only_works_for_native_code"
      "caml_allocation_profiling_min_override_profinfo" "noalloc"

  let lowest_allowable = lazy (lowest_allowable ())

  external highest_allowable : unit -> t
    = "caml_allocation_profiling_only_works_for_native_code"
      "caml_allocation_profiling_max_override_profinfo" "noalloc"

  let highest_allowable = lazy (highest_allowable ())

  let of_int t =
    if t >= Lazy.force lowest_allowable
      && t <= Lazy.force highest_allowable
    then Some t
    else None

  let to_int t = t
end

module Trace = struct
  type node
  type ocaml_node
  type foreign_node
  type uninstrumented_node

  type t = node option

  (* This function unmarshals into malloc blocks, which mean that we
     obtain a straightforward means of writing [compare] on [node]s. *)
  external unmarshal : in_channel -> 'a
    = "caml_allocation_profiling_only_works_for_native_code"
      "caml_allocation_profiling_unmarshal_trie"

  let unmarshal in_channel =
    let trace = unmarshal in_channel in
    if trace = () then
      None
    else
      Some ((Obj.magic trace) : node)

  let node_is_null (node : node) =
    ((Obj.magic node) : unit) == ()

  let foreign_node_is_null (node : foreign_node) =
    ((Obj.magic node) : unit) == ()

  external node_num_header_words : unit -> int
    = "caml_allocation_profiling_only_works_for_native_code"
      "caml_allocation_profiling_node_num_header_words" "noalloc"

  let num_header_words = lazy (node_num_header_words ())

  module OCaml = struct

    type field_iterator = {
      node : ocaml_node;
      offset : int;
    }

    module Allocation_point = struct
      type t = field_iterator

      external program_counter : ocaml_node -> int -> Program_counter.OCaml.t
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_ocaml_allocation_point_program_counter"

      let program_counter t = program_counter t.node t.offset

      external annotation : ocaml_node -> int -> Annotation.t
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_ocaml_allocation_point_annotation"
          "noalloc"

      let annotation t = annotation t.node t.offset
    end

    module Direct_call_point = struct
      type _ t = field_iterator

      external call_site : ocaml_node -> int -> Program_counter.OCaml.t
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_ocaml_direct_call_point_call_site"

      let call_site t = call_site t.node t.offset

      external callee : ocaml_node -> int -> Function_entry_point.t
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_ocaml_direct_call_point_callee"

      let callee t = callee t.node t.offset

      external callee_node : ocaml_node -> int -> 'target
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_ocaml_direct_call_point_callee_node"

      let callee_node (type target) (t : target t) : target =
        callee_node t.node t.offset
    end

    module Indirect_call_point = struct
      type t = field_iterator

      external call_site : ocaml_node -> int -> Program_counter.OCaml.t
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_ocaml_indirect_call_point_call_site"

      let call_site t = call_site t.node t.offset

      module Callee = struct
        (* CR mshinwell: we should think about the names again.  This is
           a "c_node" but it isn't foreign. *)
        type t = foreign_node

        let is_null = foreign_node_is_null

        (* CR mshinwell: maybe rename ...c_node_call_site -> c_node_pc,
           since it isn't a call site in this case. *)
        external callee : t -> Function_entry_point.t
          = "caml_allocation_profiling_only_works_for_native_code"
            "caml_allocation_profiling_c_node_call_site"

        (* This can return a node satisfying "is_null" in the case of an
           uninitialised tail call point.  See the comment in the C code. *)
        external callee_node : t -> node
          = "caml_allocation_profiling_only_works_for_native_code"
            "caml_allocation_profiling_c_node_callee_node" "noalloc"

        external next : t -> foreign_node
          = "caml_allocation_profiling_only_works_for_native_code"
            "caml_allocation_profiling_c_node_next" "noalloc"

        let next t =
          let next = next t in
          if foreign_node_is_null next then None
          else Some next
      end

      external callees : ocaml_node -> int -> Callee.t
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_ocaml_indirect_call_point_callees"
          "noalloc"

      let callees t =
        let callees = callees t.node t.offset in
        if Callee.is_null callees then None
        else Some callees
    end

    module Field = struct
      type t = field_iterator

      type direct_call_point =
        | To_ocaml of ocaml_node Direct_call_point.t
        | To_foreign of foreign_node Direct_call_point.t
        | To_uninstrumented of
            uninstrumented_node Direct_call_point.t

      type classification =
        | Allocation of Allocation_point.t
        | Direct_call of direct_call_point
        | Indirect_call of Indirect_call_point.t

      external classify : ocaml_node -> int -> int
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_ocaml_classify_field" "noalloc"

      let classify t =
        match classify t.node t.offset with
        | 0 -> Allocation t
        | 1 -> Direct_call (To_uninstrumented t)
        | 2 -> Direct_call (To_ocaml t)
        | 3 -> Direct_call (To_foreign t)
        | 4 -> Indirect_call t
        | _ -> assert false

      external skip_uninitialized : ocaml_node -> int -> int
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_ocaml_node_skip_uninitialized"
          "noalloc"

      external next : ocaml_node -> int -> int
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_ocaml_node_next" "noalloc"

      let next t =
        let offset = next t.node t.offset in
        if offset < 0 then None
        else Some { t with offset; }
    end

    module Node = struct
      type t = ocaml_node

      external function_identifier : t -> Function_identifier.t
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_ocaml_function_identifier"

      external next_in_tail_call_chain : t -> t
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_ocaml_tail_chain" "noalloc"

      external compare : t -> t -> int
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_compare_node" "noalloc"

      let fields t =
        let offset =
          Field.skip_uninitialized t (Lazy.force num_header_words)
        in
        if offset < 0 then None
        else Some { node = t; offset; }
    end
  end

  module Foreign = struct
    module Node = struct
      type t = foreign_node

      external compare : t -> t -> int
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_compare_node" "noalloc"

      let fields t =
        if foreign_node_is_null t then None
        else Some t
    end

    module Allocation_point = struct
      type t = foreign_node

      external program_counter : t -> Program_counter.Foreign.t
        (* This is not a mistake; the same C function works. *)
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_c_node_call_site"

      external annotation : t -> Annotation.t
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_c_node_profinfo" "noalloc"
    end

    module Call_point = struct
      type t = foreign_node

      external call_site : t -> Program_counter.Foreign.t
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_c_node_call_site"

      (* May return a null node.  See comment above and the C code. *)
      external callee_node : t -> node
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_c_node_callee_node" "noalloc"
    end

    module Field = struct
      type t = foreign_node

      type classification =
        | Allocation of Allocation_point.t
        | Call of Call_point.t

      external is_call : t -> bool
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_c_node_is_call" "noalloc"

      let classify t =
        if is_call t then Call t
        else Allocation t

      external next : t -> t
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_c_node_next" "noalloc"

      let next t =
        let next = next t in
        if foreign_node_is_null next then None
        else Some next
    end
  end

  module Node = struct
    module T = struct
      type t = node

      external compare : t -> t -> int
        = "caml_allocation_profiling_only_works_for_native_code"
          "caml_allocation_profiling_compare_node" "noalloc"
    end

    include T

    type classification =
      | OCaml of OCaml.Node.t
      | Foreign of Foreign.Node.t

    (* CR lwhite: These functions should work in bytecode *)
    external is_ocaml_node : t -> bool
      = "caml_allocation_profiling_only_works_for_native_code"
        "caml_allocation_profiling_is_ocaml_node" "noalloc"

    let classify t =
      if is_ocaml_node t then OCaml ((Obj.magic t) : ocaml_node)
      else Foreign ((Obj.magic t) : foreign_node)

    let of_ocaml_node (node : ocaml_node) : t = Obj.magic node
    let of_foreign_node (node : foreign_node) : t = Obj.magic node

    module Map = Map.Make (T)
    module Set = Set.Make (T)
  end

  let root t = t

  let debug_ocaml t ~resolve_return_address =
    let next_id = ref 0 in
    let visited = ref Node.Map.empty in
    let print_backtrace backtrace =
      String.concat "->" (List.map (fun return_address ->
          match resolve_return_address return_address with
          | None -> Printf.sprintf "0x%Lx" return_address
          | Some loc -> loc)
        backtrace)
    in
    let rec print_node node ~backtrace =
      match Node.Map.find node !visited with
      | id -> Printf.printf "Node %d visited before.\n%!" id
      | exception Not_found ->
        let id = !next_id in
        incr next_id;
        visited := Node.Map.add node id !visited;
        match Node.classify node with
        | Node.OCaml node ->
          Printf.printf "Node %d (OCaml node):\n%!" id;
          let module O = OCaml.Node in
          let fun_id = O.function_identifier node in
          Printf.printf "Function identifier for node: %Lx\n%!"
            (Function_identifier.to_int64 fun_id);
          Printf.printf "Tail chain for node:\n%!";
          let rec print_tail_chain node' =
            if Node.compare (Node.of_ocaml_node node)
                (Node.of_ocaml_node node') = 0
            then ()
            else begin
              let id =
                match Node.Map.find (Node.of_ocaml_node node') !visited with
                | id -> id
                | exception Not_found ->
                  let id = !next_id in
                  incr next_id;
                  (* CR mshinwell: any non-visted ones will never be
                     printed now *)
                  visited :=
                    Node.Map.add (Node.of_ocaml_node node') id !visited;
                  id
              in
              Printf.printf "  Node %d\n%!" id;
              print_tail_chain (O.next_in_tail_call_chain node')
            end
          in
          print_tail_chain (O.next_in_tail_call_chain node);
          let rec iter_fields index = function
            | None -> ()
            | Some field ->
              Printf.printf "Node %d field %d:\n%!" id index;
              let module F = OCaml.Field in
              begin match F.classify field with
              | F.Allocation alloc ->
                let pc = OCaml.Allocation_point.program_counter alloc in
                let annot = OCaml.Allocation_point.annotation alloc in
                Printf.printf "Allocation point, pc=%Lx annot=%d \
                    backtrace=%s\n%!"
                  (Program_counter.OCaml.to_int64 pc)
                  (Annotation.to_int annot)
                  (print_backtrace (List.rev backtrace))
              | F.Direct_call (F.To_ocaml direct) ->
                let module D = OCaml.Direct_call_point in
                let call_site = D.call_site direct in
                let callee = D.callee direct in
                let callee_node = D.callee_node direct in
                Printf.printf "Direct OCaml -> OCaml call point, pc=%Lx, \
                    callee=%Lx.  Callee node is:\n%!"
                  (Program_counter.OCaml.to_int64 call_site)
                  (Function_entry_point.to_int64 callee);
                print_node (Node.of_ocaml_node callee_node)
                  ~backtrace:(call_site::backtrace);
                Printf.printf "End of call point\n%!"
              | F.Direct_call (F.To_foreign direct) ->
                let module D = OCaml.Direct_call_point in
                let call_site = D.call_site direct in
                let callee = D.callee direct in
                let callee_node = D.callee_node direct in
                Printf.printf "Direct OCaml -> C call point, pc=%Lx, \
                    callee=%Lx.  Callee node is:\n%!"
                  (Program_counter.OCaml.to_int64 call_site)
                  (Function_entry_point.to_int64 callee);
                print_node (Node.of_foreign_node callee_node)
                  ~backtrace:(call_site::backtrace);
                Printf.printf "End of call point\n%!"
              | F.Direct_call (F.To_uninstrumented direct) ->
                let module D = OCaml.Direct_call_point in
                let call_site = D.call_site direct in
                let callee = D.callee direct in
                Printf.printf "Direct OCaml -> uninstrumented call point, \
                    pc=%Lx, callee=%Lx.\n%!"
                  (Program_counter.OCaml.to_int64 call_site)
                  (Function_entry_point.to_int64 callee)
              | F.Indirect_call indirect ->
                let module I = OCaml.Indirect_call_point in
                let call_site = I.call_site indirect in
                Printf.printf "Indirect call point in OCaml code, pc=%Lx:\n%!"
                  (Program_counter.OCaml.to_int64 call_site);
                let callees = I.callees indirect in
                let rec iter_callees index = function
                  | None ->
                    Printf.printf "End of callees for indirect call point.\n%!"
                  | Some callee_iterator ->
                    let module C = I.Callee in
                    let callee = C.callee callee_iterator in
                    let callee_node = C.callee_node callee_iterator in
                    if node_is_null callee_node then begin
                      Printf.printf "... uninitialised tail call point\n%!"
                    end else begin
                      Printf.printf "... callee=%Lx.  \
                          Callee node is:\n%!"
                        (Function_entry_point.to_int64 callee);
                      print_node callee_node ~backtrace:(call_site::backtrace)
                    end;
                    iter_callees (index + 1) (C.next callee_iterator)
                in
                iter_callees 0 callees
              end;
              iter_fields (index + 1) (F.next field)
          in
          iter_fields 0 (O.fields node);
          Printf.printf "End of node %d.\n%!" id
        | Node.Foreign node ->
          Printf.printf "Node %d (C node):\n%!" id;
          let rec iter_fields index = function
            | None -> ()
            | Some field ->
              Printf.printf "Node %d field %d:\n%!" id index;
              let module F = Foreign.Field in
              begin match F.classify field with
              | F.Allocation alloc ->
                let pc = Foreign.Allocation_point.program_counter alloc in
                let annot = Foreign.Allocation_point.annotation alloc in
                Printf.printf "Allocation point, pc=%Lx annot=%d, \
                    backtrace=%s\n%!"
                  (Program_counter.Foreign.to_int64 pc)
                  (Annotation.to_int annot)
                  (print_backtrace (List.rev backtrace))
              | F.Call call ->
                let call_site = Foreign.Call_point.call_site call in
                let callee_node = Foreign.Call_point.callee_node call in
                if node_is_null callee_node then begin
                  Printf.printf "... uninitialised tail call point\n%!"
                end else begin
                  Printf.printf "Call point, pc=%Lx.  Callee node is:\n%!"
                    (Program_counter.Foreign.to_int64 call_site);
                  print_node callee_node ~backtrace:(call_site::backtrace)
                end;
                Printf.printf "End of call point\n%!"
              end;
              iter_fields (index + 1) (F.next field)
          in
          iter_fields 0 (Foreign.Node.fields node);
          Printf.printf "End of node %d.\n%!" id
    in
    match root t with
    | None -> Printf.printf "Trace is empty.\n%!"
    | Some node -> print_node node ~backtrace:[]

  let to_json t channel
      ~(resolve_address : ?long:unit -> Program_counter.OCaml.t -> string) =
    output_string channel "{\n";
    output_string channel "\"nodes\":[\n";
    let seen_a_node = ref false in
    let next_id = ref 0 in
    let visited = ref Node.Map.empty in
    let allocation_nodes = true in
    let rec print_node node =
      match Node.Map.find node !visited with
      | id -> ()
      | exception Not_found ->
        let id = !next_id in
        incr next_id;
        visited := Node.Map.add node id !visited;
        if !seen_a_node then begin
          (* Trailing commas are not allowed. *)
          Printf.fprintf channel ",\n"
        end;
        let first_node = (!seen_a_node = false) in
        seen_a_node := true;
        match Node.classify node with
        | Node.OCaml node ->
          let module O = OCaml.Node in
          let fun_id = O.function_identifier node in
          Printf.fprintf channel "{\"name\":\"%Lx\",\"colour\":%d}%!"
            (Function_identifier.to_int64 fun_id)
            (if first_node then 17 else 2);
          let rec iter_fields = function
            | None -> ()
            | Some field ->
              let module F = OCaml.Field in
              begin match F.classify field with
              | F.Allocation alloc ->
                if allocation_nodes then begin
                  let pc = OCaml.Allocation_point.program_counter alloc in
                  Printf.fprintf channel ",\n{\"name\":\"%s\",\"colour\":3}%!"
                    (resolve_address ~long:() pc);
                  incr next_id
                end
              | F.Direct_call (F.To_ocaml direct) ->
                let module D = OCaml.Direct_call_point in
                let callee_node = D.callee_node direct in
                print_node (Node.of_ocaml_node callee_node)
              | F.Direct_call (F.To_foreign direct) ->
                let module D = OCaml.Direct_call_point in
                let callee_node = D.callee_node direct in
                print_node (Node.of_foreign_node callee_node)
              | F.Direct_call (F.To_uninstrumented _direct) -> ()
              | F.Indirect_call indirect ->
                let module I = OCaml.Indirect_call_point in
                let callees = I.callees indirect in
                let rec iter_callees = function
                  | None -> ()
                  | Some callee_iterator ->
                    let module C = I.Callee in
                    let callee_node = C.callee_node callee_iterator in
                    if not (node_is_null callee_node) then begin
                      print_node callee_node
                    end;
                    iter_callees (C.next callee_iterator)
                in
                iter_callees callees
              end;
              iter_fields (F.next field)
          in
          iter_fields (O.fields node)
        | Node.Foreign node ->
          let name =
            (* CR mshinwell: instead of doing this we should find out the
               address of the top of the function and use that. *)
            let rec iter_fields name = function
              | None -> name
              | Some field ->
                let module F = Foreign.Field in
                let name =
                  match F.classify field with
                  | F.Allocation _alloc -> name
                  | F.Call call ->
                    let call_site = Foreign.Call_point.call_site call in
                    Printf.sprintf "%s %Lx"
                      name
                      (Program_counter.Foreign.to_int64 call_site)
                in
                iter_fields name (F.next field)
            in
            iter_fields "C, calls: " (Foreign.Node.fields node)
          in
          Printf.fprintf channel "{\"name\":\"%s\",\"colour\":0}%!" name;
          let rec iter_fields = function
            | None -> ()
            | Some field ->
              let module F = Foreign.Field in
              begin match F.classify field with
              | F.Allocation _alloc ->
                if allocation_nodes then begin
                  Printf.fprintf channel ",\n{\"name\":\"C\",\"colour\":3}%!";
                  incr next_id
                end
              | F.Call call ->
                let callee_node = Foreign.Call_point.callee_node call in
                if not (node_is_null callee_node) then begin
                  print_node callee_node
                end
              end;
              iter_fields (F.next field)
          in
          iter_fields (Foreign.Node.fields node)
    in
    begin match root t with
    | None -> ()
    | Some node -> print_node node
    end;
    seen_a_node := false;
    next_id := 0;
    let link_id = ref 0 in
    visited := Node.Map.empty;
    output_string channel "],\n";
    output_string channel "\"links\":[\n";
    let rec print_node ?come_from node =
      let check_come_from ~id ~comma =
        begin match come_from with
        | None -> ()
        | Some (come_from, colour, label) ->
          if comma && !seen_a_node then begin
            Printf.fprintf channel ",\n"
          end;
          Printf.fprintf channel
            "{\"source\":%d,\"target\":%d,\"value\":10,\"colour\":%d,\
              \"label\":\"%s\",\"id\":%d}%!"
            come_from id colour label !link_id;
          incr link_id;
          seen_a_node := true
        end
      in
      match Node.Map.find node !visited with
      | id -> check_come_from ~id ~comma:true
      | exception Not_found ->
        let id = !next_id in
        incr next_id;
        visited := Node.Map.add node id !visited;
        if !seen_a_node then begin
          (* Apparently JSON doesn't allow trailing commas. *)
          Printf.fprintf channel ",\n"
        end;
        let c_colour = 16 in
        let direct_colour = 5 in
        let external_colour = 9 in
        let indirect_colour = 14 in
        check_come_from ~id ~comma:false;
        match Node.classify node with
        | Node.OCaml node ->
          let module O = OCaml.Node in
          let rec iter_fields = function
            | None -> ()
            | Some field ->
              let module F = OCaml.Field in
              begin match F.classify field with
              | F.Allocation alloc ->
                if allocation_nodes then begin
                  Printf.fprintf channel
                    ",\n{\"source\":%d,\"target\":%d,\"value\":1,\
                      \"colour\":3,\"id\":%d}%!"
                    id !next_id !link_id;
                  incr link_id;
                  incr next_id
                end
              | F.Direct_call (F.To_ocaml direct) ->
                let module D = OCaml.Direct_call_point in
                let callee_node = D.callee_node direct in
                let call_site = D.call_site direct in
                let label = resolve_address call_site in
                print_node (Node.of_ocaml_node callee_node)
                  ~come_from:(id, direct_colour, label)
              | F.Direct_call (F.To_foreign direct) ->
                let module D = OCaml.Direct_call_point in
                let callee_node = D.callee_node direct in
                let call_site = D.call_site direct in
                let label = resolve_address call_site in
                print_node (Node.of_foreign_node callee_node)
                  ~come_from:(id, external_colour, label)
              | F.Direct_call (F.To_uninstrumented _direct) -> ()
              | F.Indirect_call indirect ->
                let module I = OCaml.Indirect_call_point in
                let callees = I.callees indirect in
                let call_site = I.call_site indirect in
                let label = resolve_address call_site in
                let rec iter_callees = function
                  | None -> ()
                  | Some callee_iterator ->
                    let module C = I.Callee in
                    let callee_node = C.callee_node callee_iterator in
                    if not (node_is_null callee_node) then begin
                      print_node callee_node
                        ~come_from:(id, indirect_colour, label)
                    end;
                    iter_callees (C.next callee_iterator)
                in
                iter_callees callees
              end;
              iter_fields (F.next field)
          in
          iter_fields (O.fields node)
        | Node.Foreign node ->
          let rec iter_fields = function
            | None -> ()
            | Some field ->
              let module F = Foreign.Field in
              begin match F.classify field with
              | F.Allocation _alloc ->
                if allocation_nodes then begin
                  Printf.fprintf channel
                    ",\n{\"source\":%d,\"target\":%d,\"value\":1,\
                      \"colour\":3,\"id\":%d}%!"
                    id !next_id !link_id;
                  incr link_id;
                  incr next_id
                end
              | F.Call call ->
                let callee_node = Foreign.Call_point.callee_node call in
                if not (node_is_null callee_node) then begin
                  print_node callee_node ~come_from:(id, c_colour, "")
                end
              end;
              iter_fields (F.next field)
          in
          iter_fields (Foreign.Node.fields node)
    in
    begin match root t with
    | None -> ()
    | Some node -> print_node node
    end;
    output_string channel "]\n";
    output_string channel "}"
end

module Heap_snapshot = struct

  module Entries = struct
    type t = int array  (* == "struct snapshot_entries" *)

    let length t =
      let length = Array.length t in
      assert (length mod 3 = 0);
      length / 3

    let annotation t idx = t.(idx*3)
    let num_blocks t idx = t.(idx*3 + 1)
    let num_words_including_headers t idx = t.(idx*3 + 2)

  end

  type t = {
    timestamp : float;
    gc_stats : Gc_stats.t;
    entries : Entries.t;
    num_blocks_in_minor_heap : int;
    num_blocks_in_major_heap : int;
    num_blocks_in_minor_heap_with_profinfo : int;
    num_blocks_in_major_heap_with_profinfo : int;
  }

  type heap_snapshot = t

  let timestamp t = t.timestamp
  let gc_stats t = t.gc_stats
  let entries t = t.entries
  let num_blocks_in_minor_heap t =
    t.num_blocks_in_minor_heap
  let num_blocks_in_major_heap t =
    t.num_blocks_in_major_heap
  let num_blocks_in_minor_heap_with_profinfo t =
    t.num_blocks_in_minor_heap_with_profinfo
  let num_blocks_in_major_heap_with_profinfo t =
    t.num_blocks_in_major_heap_with_profinfo

  module Series = struct
    type t = {
      num_snapshots : int;
      time_of_writer_close : float;
      frame_table : Frame_table.t;
      traces_by_thread : Trace.t array;
      finaliser_traces_by_thread : Trace.t array;
      snapshots : heap_snapshot array;
    }

    let pathname_suffix_trace = "trace"

    let read ~pathname_prefix =
      let pathname_prefix = pathname_prefix ^ "." in
      let chn = open_in (pathname_prefix ^ pathname_suffix_trace) in
      let num_snapshots : int = Marshal.from_channel chn in
      let time_of_writer_close : float = Marshal.from_channel chn in
      let frame_table : Frame_table.t = Marshal.from_channel chn in
      let num_threads : int = Marshal.from_channel chn in
      let traces_by_thread = Array.init num_threads (fun _ -> None) in
      let finaliser_traces_by_thread =
        Array.init num_threads (fun _ -> None)
      in
      for thread = 0 to num_threads - 1 do
        let trace : Trace.t = Trace.unmarshal chn in
        let finaliser_trace : Trace.t = Trace.unmarshal chn in
        traces_by_thread.(thread) <- trace;
        finaliser_traces_by_thread.(thread) <- finaliser_trace
      done;
      close_in chn;
      let snapshots =
        Array.init num_snapshots (fun index ->
          let chn = open_in (pathname_prefix ^ (string_of_int index)) in
          let snapshot = Marshal.from_channel chn in
          close_in chn;
          snapshot)
      in
      { num_snapshots;
        time_of_writer_close;
        frame_table;
        traces_by_thread;
        finaliser_traces_by_thread;
        snapshots;
      }

    type trace_kind = Normal | Finaliser

    let num_threads t = Array.length t.traces_by_thread

    let trace t ~kind ~thread_index =
      if thread_index < 0 || thread_index >= num_threads t then None
      else
        match kind with
        | Normal -> Some t.traces_by_thread.(thread_index)
        | Finaliser -> Some t.finaliser_traces_by_thread.(thread_index)

    let num_snapshots t = t.num_snapshots
    let snapshot t ~index = t.snapshots.(index)
    let frame_table t = t.frame_table
    let time_of_writer_close t = t.time_of_writer_close
  end
end
