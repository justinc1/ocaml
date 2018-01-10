(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2018 OCamlPro SAS                                    *)
(*   Copyright 2014--2018 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-9-30-40-41-42"]

module A = Number_adjuncts
module B = Inlining_cost.Benefit
module E = Simplify_env_and_result.Env
module K = Flambda_kind
module R = Simplify_env_and_result.Result
module S = Simplify_simple
module T = Flambda_type

module Float_by_bit_pattern = Numbers.Float_by_bit_pattern
module Int32 = Numbers.Int32
module Int64 = Numbers.Int64
module Named = Flambda.Named
module Reachable = Flambda.Reachable

let simplify_project_closure env r prim ~closure ~set_of_closures dbg =
  let arg, ty = S.simplify_simple env arg in
  let original_term () : Named.t = Prim (Unary (prim, arg), dbg) in
  let invalid () =
    Reachable.invalid (), T.bottom (K.value Definitely_pointer),
      R.map_benefit r (B.remove_primitive (Unary prim))
  in
  let proof = (E.type_accessor env T.prove_set_of_closures) ty in
  (* CR mshinwell: We need to think about the old "project_var Projection.t"
     thing which is used for unboxing of free variables of closures *)
  match proof with
  | Proved set_of_closures ->
    begin T.Set_of_closures.project_closure set_of_closures closure with
    | Not_in_set -> invalid ()
    | Ok closure_ty ->
      Reachable.reachable (original_term ()), closure_ty, r
    end
  | Unknown ->
    Reachable.reachable (original_term ()), T.any_closure (), r
  | Invalid -> invalid ()

let simplify_move_within_set_of_closures env r prim ~move_from ~move_to
      ~closure dbg =
  let arg, ty = S.simplify_simple env arg in
  let original_term () : Named.t = Prim (Unary (prim, arg), dbg) in
  let invalid () =
    Reachable.invalid (), T.bottom (K.value Definitely_pointer),
      R.map_benefit r (B.remove_primitive (Unary prim))
  in
  let proof = (E.type_accessor env T.prove_closures) ty in
  match proof with
  | Proved by_closure_id ->
    begin match Closure_id.Map.find move_from by_closure_id with
    | exception Not_found -> invalid ()
    | set_of_closures_name, set_of_closures ->
      begin T.Set_of_closures.project_closure set_of_closures move_to with
      | Not_in_set -> invalid ()
      | Ok closure_ty ->
        begin match set_of_closures_name with
        | None ->
          Reachable.reachable (original_term ()), closure_ty, r
        | Some name ->
          let r =
            R.map_benefit
              (R.map_benefit r (B.remove_primitive (Unary prim)))
              (B.add_primitive (Unary Project_closure))
          in
          let new_term : Named.t =
            Prim (Unary (Project_closure move_to, Simple.name name), dbg)
          in
          Reachable.reachable new_term, closure_ty, r
        end
      end
    end
  | Unknown ->
    Reachable.reachable (original_term ()), T.any_closure (), r
  | Invalid -> invalid ()

let simplify_project_var env r prim ~closure_id ~var_within_closure
      ~closure dbg =
  let arg, ty = S.simplify_simple env arg in
  let original_term () : Named.t = Prim (Unary (prim, arg), dbg) in
  let invalid () =
    Reachable.invalid (), T.bottom (K.value Unknown)
      R.map_benefit r (B.remove_primitive (Unary prim))
  in
  let proof = (E.type_accessor env T.prove_closures) ty in
  match proof with
  | Proved by_closure_id ->
    begin match Closure_id.Map.find move_from by_closure_id with
    | exception Not_found ->

    | ... ->

    end
  | Unknown ->
    Reachable.reachable (original_term ()), T.any_value (), r
  | Invalid -> invalid ()


(*
(* Simplify an expression that, given one closure within some set of
   closures, returns another closure (possibly the same one) within the
   same set. *)
let simplify_move_within_set_of_closures env r
      ~(move_within_set_of_closures : Projection.Move_within_set_of_closures.t)
      : named_simplifier =
  let closure, closure_ty =
    freshen_and_squash_aliases env move_within_set_of_closures.closure
  in
  match T.prove_closure_allowing_unresolved closure_ty with
  | Wrong ->
    Misc.fatal_errorf "Wrong Flambda type when moving within set of \
        closures.  Flambda type: %a  Term: %a"
      T.print closure_ty
      Flambda.print_move_within_set_of_closures move_within_set_of_closures
  | Unresolved sym ->
    [], Reachable (Move_within_set_of_closures {
        closure;
        move = move_within_set_of_closures.move;
      }),
      ret r (T.unresolved_symbol sym)
  | Unknown ->
    [], Reachable (Move_within_set_of_closures {
        closure;
        move = move_within_set_of_closures.move;
      }),
      ret r (T.unknown Value Other)
  | Unknown_because_of_unresolved_value value ->
    (* For example: a move upon a (move upon a closure whose .cmx file
        is missing). *)
    [], Reachable (Move_within_set_of_closures {
        closure;
        move = move_within_set_of_closures.move;
      }),
      ret r (T.unknown Value (Unresolved_value value))
  | Ok (value_closures, set_of_closures_var, set_of_closures_symbol) ->
    let () =
      match Closure_id.Map.bindings value_closures with
      | _ :: _ :: _ ->
        Format.printf "Closure type is not a singleton in \
            move@ %a@ %a@."
          T.print closure_ty
          Projection.print_move_within_set_of_closures
          move_within_set_of_closures
      | [] ->
        Format.printf "Closure type is empty in move@ %a@ %a@."
          T.print closure_ty
          Projection.print_move_within_set_of_closures
          move_within_set_of_closures
      | _ ->
        ()
    in
    (* Freshening of the move. *)
    let move, type_map =
      Closure_id.Map.fold
        (fun closure_id_in_type
              (value_set_of_closures:T.set_of_closures)
              (move, type_map) ->
          (* Pas efficace: on refait le freshening de tout pour ne
             garder que la partie pertinente, mais n'est pas très
             grave parce que ces map sont petites (normalement) *)
          let freshened_move =
            Freshening.freshen_move_within_set_of_closures
              ~closure_freshening:value_set_of_closures.freshening
              move_within_set_of_closures.move
          in
          let start_from = closure_id_in_type in
          let move_to =
            try Closure_id.Map.find start_from freshened_move with
            | Not_found ->
              Misc.fatal_errorf "Move %a freshened to %a does not contain \
                                  projection for %a@.  Type is:@ %a@.\
                                  Environment:@ %a@."
                Projection.print_move_within_set_of_closures
                  move_within_set_of_closures
                (Closure_id.Map.print Closure_id.print) freshened_move
                Closure_id.print start_from
                (Closure_id.Map.print T.print_value_set_of_closures)
                  value_closures
                E.print env
          in
          assert(not (Closure_id.Map.mem start_from move));
          Closure_id.Map.add start_from move_to move,
          Closure_id.Map.add move_to value_set_of_closures type_map)
        value_closures (Closure_id.Map.empty, Closure_id.Map.empty)
    in
    let projection : Projection.t =
      Move_within_set_of_closures {
        closure;
        move;
      }
    in
    match Closure_id.Map.get_singleton value_closures,
          Closure_id.Map.get_singleton move with
    | None, Some _ | Some _, None ->
      (* After the freshening, move and value_closures have the same
         cardinality *)
      assert false
    | None, None ->
      let ty = T.closure ty_map in
      let move_within : Projection.Move_within_set_of_closures.t =
        { closure; move; }
      in
      [], Reachable (Move_within_set_of_closures move_within), ty
    | Some (_start_from, value_set_of_closures),
      Some (start_from, move_to) ->
      match E.find_projection env ~projection with
      | Some var ->
        freshen_and_squash_aliases_named env var ~f:(fun _env var var_ty ->
          let r = R.map_benefit r (B.remove_projection projection) in
          [], Reachable (Var var), var_ty)
      | None ->
        match reference_recursive_function_directly env move_to with
        | Some (flam, ty) -> [], Reachable flam, ty
        | None ->
          if Closure_id.equal start_from move_to then
            (* Moving from one closure to itself is a no-op.  We can return an
               [Var] since we already have a variable bound to the closure. *)
            [], Reachable (Var closure), closure_ty
          else
            match set_of_closures_var with
            | Some set_of_closures_var when E.mem env set_of_closures_var ->
              (* A variable bound to the set of closures is in scope,
                 meaning we can rewrite the [Move_within_set_of_closures] to a
                 [Project_closure]. *)
              let project_closure : Projection.Project_closure.t =
                { set_of_closures = set_of_closures_var;
                  closure_id = Closure_id.Set.singleton move_to;
                }
              in
              let ty =
                T.closure ~set_of_closures_var
                  (Closure_id.Map.singleton move_to value_set_of_closures)
              in
              [], Reachable (Project_closure project_closure), ty
            | Some _ | None ->
              match set_of_closures_symbol with
              | Some set_of_closures_symbol ->
                let set_of_closures_var = Variable.create "symbol" in
                let project_closure : Projection.Project_closure.t =
                  { set_of_closures = set_of_closures_var;
                    closure_id = Closure_id.Set.singleton move_to;
                  }
                in
                let ty =
                  T.closure ~set_of_closures_var ~set_of_closures_symbol
                    (Closure_id.Map.singleton move_to value_set_of_closures)
                in
                let bindings : (Variable.t * Named.t) list = [
                  set_of_closures_var, Symbol set_of_closures_symbol;
                ]
                in
                bindings, Reachable (Project_closure project_closure),
                  ty
              | None ->
                (* The set of closures is not available in scope, and we
                  have no other information by which to simplify the move. *)
                let move_within : Projection.Move_within_set_of_closures.t =
                  { closure; move; }
                in
                let ty = T.closure ty_map in
                [], Reachable (Move_within_set_of_closures move_within), ty

let rec simplify_project_var env r ~(project_var : Projection.Project_var.t)
      : named_simplifier =
  let closure, closure_ty =
    freshen_and_squash_aliases env project_var.closure
  in
  match T.prove_closure_allowing_unresolved closure_ty with
  | Ok (value_closures, _set_of_closures_var, _set_of_closures_symbol) ->
(*
    let () =
      match Closure_id.Map.bindings value_closures with
        | _ :: _ :: _ ->
          Format.printf "Closure type is not a singleton in \
              project@ %a@ %a@."
            T.print ty
            Projection.print_project_var project_var
        | [] ->
          Format.printf "Closure type is empty in project@ %a@ %a@."
            T.print ty
            Projection.print_project_var project_var
        | _ ->
          ()
    in
*)
    (* Freshening of the projection *)
    let project_var_var, ty =
      Closure_id.Map.fold
        (fun closure_id_in_type
          (value_set_of_closures : T.set_of_closures)
          (project_var_var, set_type) ->
          let freshened_var =
            Freshening.freshen_project_var project_var.var
              ~closure_freshening:value_set_of_closures.freshening
          in
          let closure_id = closure_id_in_type in
          let var =
            try Closure_id.Map.find closure_id_in_type freshened_var with
            | Not_found ->
              Misc.fatal_errorf "When simplifying [Project_var], the \
                closure ID %a in the type of the set of closures \
                did not match any closure ID in the [Project_var] term %a \
                freshened to %a. \
                Type: %a@."
                Closure_id.print closure_id_in_type
                Projection.print_project_var project_var
                (Closure_id.Map.print Var_within_closure.print) freshened_var
                Flambda_type.print ty
          in
          let set_type =
            let ty = T.type_for_bound_var value_set_of_closures var in
            let really_import_type = E.really_import_type env in
            T.join ~really_import_type ty set_type
          in
          Closure_id.Map.add closure_id var project_var_var,
          set_type)
        value_closures (Closure_id.Map.empty, T.bottom)
    in
    let projection : Projection.t =
      Project_var {
        closure;
        var = project_var_var;
      }
    in
    begin match E.find_projection env ~projection with
    | Some var ->
      freshen_and_squash_aliases_named env var ~f:(fun _env var var_ty ->
        let r = R.map_benefit r (B.remove_projection projection) in
        [], Reachable (Var var), var_ty)
    | None ->
      let expr : Named.t =
        Project_var { closure; var = project_var_var; }
      in
      let expr =
        match Closure_id.Map.get_singleton project_var_var with
        | None ->
          expr
        | Some (_closure_id, var) ->
          let unwrapped = Var_within_closure.unwrap var in
          if E.mem env unwrapped then
            Flambda.Var unwrapped
          else
            expr
      in
      simpler_equivalent_term env r expr ty
    end
  | Unknown ->
    [], Reachable.reachable (Project_var { project_var with closure }),
      r
  | Wrong ->
    [], Reachable.invalid (), r

*)

let simplify_duplicate_block _env _r _prim _arg _dbg
      ~(kind : Flambda_primitive.duplicate_block_kind)
      ~source_mutability:_ ~destination_mutability:_ =
  ignore kind; assert false
(* Let's finish this later
  let arg, ty = S.simplify_simple env arg in
  let original_term () : Named.t = Prim (Unary (prim, arg), dbg) in
  let kind_of_block = K.value Definitely_pointer in
  let full_of_values ~template =
    let proof = (E.type_accessor env T.prove_block) ty in
    match proof with
    | Proved blocks ->
      let new_block_tys =
        T.Blocks.fold blocks
          ~init:[]
          ~f:(fun new_block_tys block ->
            let module B = T.Blocks.Block in
            let tag = B.tag block in
            if not (Tag.Scannable.equal tag new_tag) then
              new_block_tys
            else
              let ty =
                match destination_mutability with
                | Mutable ->
                  let field_tys = B.fields block in
                  T.block tag (T.unknown_like_array field_tys)
                | Immutable ->
                  B.to_type block
              in
              let ty = (E.type_accessor env T.meet_of_kind_value) ty template in
              ty :: new_block_tys)
      in
      let type_of_new_block = (E.type_accessor env T.join) new_block_tys in
      Reachable.reachable (original_term ()), type_of_new_block
    | Unknown ->
      let type_of_new_block =
        let ty =
          match destination_mutability with
          | Mutable -> T.unknown kind_of_block Other
          | Immutable -> ty
        in
        (E.type_accessor env T.meet_of_kind_value) ty template
      in
      Reachable.reachable (original_term ()), type_of_new_block
    | Invalid ->
      Reachable.invalid (), T.bottom kind_of_block
  in
  let full_of_naked_floats ~template =
    let proof = (E.type_accessor env T.prove_float_array) ty in
    match proof with
    | Proved arrays ->
      let new_block_tys =
        Targetint.OCaml.Set.fold (fun fields new_block_tys ->
            let size = Array.length fields in
            let ty =
              match destination_mutability with
              | Mutable -> T.mutable_float_array ~size
              | Immutable -> T.immutable_float_array fields
            in
            let ty =
              (E.type_accessor env T.meet_of_kind_naked_float) ty template
            in
            ty :: new_block_tys)
          arrays
          []
      in
      let type_of_new_block = (E.type_accessor env T.join) new_block_tys in
      Reachable.reachable (original_term ()), type_of_new_block
    | Unknown ->
      let type_of_new_block =
        let ty =
          match destination_mutability with
          | Mutable -> T.unknown kind_of_block Other
          | Immutable -> ty
        in
        (E.type_accessor env T.meet_of_kind_value) ty template
      in
      Reachable.reachable (original_term ()), type_of_new_block
    | Invalid ->
      Reachable.invalid (), T.bottom kind_of_block
  in
  let term, ty =
    match kind with
    | Full_of_values_known_length (new_tag, new_value_kinds) ->
      let unknown_type_of_new_block =
        T.constraint_block new_tag new_value_kinds
      in
      full_of_values ~template:(Some unknown_type_of_new_block)
    | Full_of_values_unknown_length (new_tag, new_value_kind) ->
      full_of_values ~template:None
    | Full_of_naked_floats { length; } ->
      let size_constraint =
        match length with
        | None -> None
        | Some size -> Some (T.constraint_float_array ~size)
      in
      full_of_naked_floats ~template:size_constraint
    | Generic_array _ -> assert false
      (* To finish later.  (Also, evict to [Simplify_generic_array].) *)
  in
  term, ty, r
*)

let simplify_is_int env r prim arg dbg =
  let arg, ty = S.simplify_simple env arg in
  let original_term () : Named.t = Prim (Unary (prim, arg), dbg) in
  let proof = (E.type_accessor env T.prove_is_tagged_immediate) ty in
  match proof with
  | Proved is_tagged_immediate ->
    let simple = Simple.const_bool is_tagged_immediate in
    let imm = Immediate.bool is_tagged_immediate in
    Reachable.reachable (Simple simple), T.this_tagged_immediate imm,
      R.map_benefit r (B.remove_primitive (Unary prim))
  | Unknown ->
    Reachable.reachable (original_term ()),
      T.these_tagged_immediates Immediate.all_bools, r
  | Invalid -> 
    Reachable.invalid (), T.bottom (K.value Definitely_immediate),
      R.map_benefit r (B.remove_primitive (Unary prim))

let simplify_get_tag env r prim ~tags_to_sizes ~block dbg =
  let block, block_ty = S.simplify_simple env block in
  let inferred_tags = (E.type_accessor env T.prove_tags) block_ty in
  let possible_tags = Tag.Scannable.Map.keys tags_to_sizes in
  let invalid r =
    Reachable.invalid (), T.bottom (K.fabricated Definitely_immediate),
      R.map_benefit r (B.remove_primitive (Unary prim))
  in
  let result_var_type ~tags_to_sizes =
    let tags_to_env_extensions =
      Tag.Scannable.Map.fold (fun tag size tags_to_env_extensions ->
          (* CR mshinwell: thikn about this conversion *)
          let size = Targetint.OCaml.to_int size in
          let block_ty = T.block_of_unknown_values tag Unknown ~size in
          let env =
            match block with
            | Const _ ->
              (* CR mshinwell: This is kind of silly---it will never be a
                 [Const] *)
              T.Typing_environment.create ()
            | Name block ->
              T.Typing_environment.add (T.Typing_environment.create ())
                block (E.continuation_scope_level env) block_ty
          in
          Tag.Map.add (Tag.Scannable.to_tag tag) env tags_to_env_extensions)
        tags_to_sizes
        Tag.Map.empty
    in
    T.these_tags tags_to_env_extensions
  in
  match inferred_tags with
  | Proved inferred_tags ->
    let inferred_tags = Tag.to_scannable_set inferred_tags in
    let tags = Tag.Scannable.Set.inter inferred_tags possible_tags in
    let r =
      R.map_benefit r (B.remove_primitive (Unary (Get_tag { tags_to_sizes; })))
    in
    if Tag.Scannable.Set.is_empty tags then begin
      invalid r
    end else begin
      let tags_to_sizes =
        Tag.Scannable.Map.filter
          (fun tag _size -> Tag.Scannable.Set.mem tag inferred_tags)
          tags_to_sizes
      in
      assert (not (Tag.Scannable.Map.is_empty tags_to_sizes));
      let prim : Flambda_primitive.unary_primitive =
        Get_tag { tags_to_sizes; }
      in
      let term : Named.t = Prim (Unary (prim, block), dbg) in
      let result_var_type = result_var_type ~tags_to_sizes in
      Reachable.reachable term, result_var_type, r
    end
  | Unknown ->
    let prim : Flambda_primitive.unary_primitive =
      Get_tag { tags_to_sizes; }
    in
    let term : Named.t = Prim (Unary (prim, block), dbg) in
    let result_var_type = result_var_type ~tags_to_sizes in
    Reachable.reachable term, result_var_type, r
  | Invalid -> invalid r

module Make_simplify_unbox_number (P : A.Boxable_number_kind) = struct
  let simplify env r prim arg dbg =
    let arg, ty = S.simplify_simple env arg in
    let original_term () : Named.t = Prim (Unary (prim, arg), dbg) in
    let proof = (E.type_accessor env P.boxed_prover) ty in
    let kind = K.Standard_int_or_float.to_kind P.kind in
    let unknown () =
      Reachable.reachable (original_term ()), T.unknown kind, r
    in
    let invalid () =
      Reachable.invalid (), T.bottom kind,
        R.map_benefit r (B.remove_primitive (Unary prim))
    in
    match proof with
    | Proved unboxed_ty ->
      let unboxed_ty = P.t_of_ty unboxed_ty in
      let proof = (E.type_accessor env P.unboxed_prover) unboxed_ty in
      begin match proof with
      | Proved nums ->
        Reachable.reachable (original_term ()), P.these_unboxed nums,
          R.map_benefit r (B.remove_primitive (Unary prim))
      | Unknown -> unknown ()
        (* In this case, [unboxed_ty] might actually be an alias, meaning
           that we can replace the primitive with a variable.  This will be
           done automagically by the code in [Simplify_named] using
           [reify]. *)
      | Invalid -> invalid ()
      end
    | Unknown -> unknown ()
    | Invalid -> invalid ()
end

module Simplify_unbox_number_float = Make_simplify_unbox_number (A.For_floats)
module Simplify_unbox_number_int32 = Make_simplify_unbox_number (A.For_int32s)
module Simplify_unbox_number_int64 = Make_simplify_unbox_number (A.For_int64s)
module Simplify_unbox_number_nativeint =
  Make_simplify_unbox_number (A.For_nativeints)

module Make_simplify_box_number (P : A.Boxable_number_kind) = struct
  let simplify env r prim arg dbg =
    (* CR mshinwell: If [arg] is already a [Const] we shouldn't have to do
       much work... *)
    let arg, ty = S.simplify_simple env arg in
    let original_term () : Named.t = Prim (Unary (prim, arg), dbg) in
    let proof = (E.type_accessor env P.unboxed_prover) ty in
    match proof with
    | Proved nums ->
      (* begin match P.Num.Set.get_singleton nums with
      | Some n ->
        let symbol, r = R.new_lifted_constant r (Boxed_float (Const n)) in
        let r = R.map_benefit r (B.remove_primitive (Unary prim)) in
        let named : Named.t = Simple (Simple.name (Name.symbol symbol)) in
        Reachable.reachable named, P.this n, r
      | None -> ...
      end *)
      assert (not (P.Num.Set.is_empty nums));
      Reachable.reachable (original_term ()), P.these_unboxed nums, r
    | Unknown ->
      Reachable.reachable (original_term ()), P.box ty, r
    | Invalid -> 
      Reachable.invalid (), T.bottom (K.value Definitely_pointer), r
end

module Simplify_box_number_float = Make_simplify_box_number (A.For_floats)
module Simplify_box_number_int32 = Make_simplify_box_number (A.For_int32s)
module Simplify_box_number_int64 = Make_simplify_box_number (A.For_int64s)
module Simplify_box_number_nativeint =
  Make_simplify_box_number (A.For_nativeints)

module Unary_int_arith (I : A.Int_number_kind) = struct
  let simplify env r prim dbg (op : Flambda_primitive.unary_int_arith_op) arg =
    let arg, arg_ty = S.simplify_simple env arg in
    let proof = (E.type_accessor env I.unboxed_prover) arg_ty in
    let original_term () : Named.t = Prim (Unary (prim, arg), dbg) in
    let result_unknown () =
      (* One might imagine doing something complicated to [ty] to reflect
         the operation that has happened, but we don't.  As such we cannot
         propagate [ty] and must return "unknown". *)
      Reachable.reachable (original_term ()),
        T.unknown (K.Standard_int_or_float.to_kind I.kind),
        r
    in
    let result_invalid () =
      Reachable.invalid (),
        T.bottom (K.Standard_int_or_float.to_kind I.kind),
        R.map_benefit r (B.remove_primitive (Unary prim))
    in
    match proof with
    | Proved ints ->
      assert (not (I.Num.Set.is_empty ints));
      begin match op with
      | Neg ->
        let possible_results = I.Num.Set.map (fun i -> I.Num.neg i) ints in
        Reachable.reachable (original_term ()),
          I.these_unboxed possible_results, r
      | Swap_byte_endianness ->
        let possible_results =
          I.Num.Set.map (fun i -> I.Num.swap_byte_endianness i) ints
        in
        Reachable.reachable (original_term ()),
          I.these_unboxed possible_results, r
      end
    | Unknown -> result_unknown ()
    | Invalid -> result_invalid ()
end

module Unary_int_arith_tagged_immediate =
  Unary_int_arith (A.For_tagged_immediates)
module Unary_int_arith_naked_int32 = Unary_int_arith (A.For_int32s)
module Unary_int_arith_naked_int64 = Unary_int_arith (A.For_int64s)
module Unary_int_arith_naked_nativeint = Unary_int_arith (A.For_nativeints)

module Make_simplify_int_conv (N : A.Number_kind) = struct
  module F = Float_by_bit_pattern

  let simplify env r prim arg ~(dst : K.Standard_int_or_float.t) dbg =
    let arg, arg_ty = S.simplify_simple env arg in
    if K.Standard_int_or_float.equal N.kind dst then
      if (E.type_accessor env T.is_bottom) arg_ty then
        Reachable.invalid (),
          T.bottom (K.Standard_int_or_float.to_kind dst),
          R.map_benefit r (B.remove_primitive (Unary prim))
      else
        Reachable.reachable (Flambda.Named.Simple arg), arg_ty, r
    else
      let proof = (E.type_accessor env N.unboxed_prover) arg_ty in
      let original_term () : Named.t = Prim (Unary (prim, arg), dbg) in
      match proof with
      | Proved is ->
        assert (N.Num.Set.cardinal is > 0);
        begin match dst with
        | Tagged_immediate ->
          let imms =
            N.Num.Set.fold (fun i imms ->
                Immediate.Set.add (N.Num.to_tagged_immediate i) imms)
              is
              Immediate.Set.empty
          in
          Reachable.reachable (original_term ()),
            T.these_tagged_immediates imms,
            r
        | Naked_float ->
          let is =
            N.Num.Set.fold (fun i is ->
                F.Set.add (N.Num.to_naked_float i) is)
              is
              F.Set.empty
          in
          Reachable.reachable (original_term ()), T.these_naked_floats is, r
        | Naked_int32 ->
          let is =
            N.Num.Set.fold (fun i is ->
                Int32.Set.add (N.Num.to_naked_int32 i) is)
              is
              Int32.Set.empty
          in
          Reachable.reachable (original_term ()), T.these_naked_int32s is, r
        | Naked_int64 ->
          let is =
            N.Num.Set.fold (fun i is ->
                Int64.Set.add (N.Num.to_naked_int64 i) is)
              is
              Int64.Set.empty
          in
          Reachable.reachable (original_term ()), T.these_naked_int64s is, r
        | Naked_nativeint ->
          let is =
            N.Num.Set.fold (fun i is ->
                Targetint.Set.add (N.Num.to_naked_nativeint i) is)
              is
              Targetint.Set.empty
          in
          Reachable.reachable (original_term ()),
            T.these_naked_nativeints is, r
        end
      | Unknown ->
        Reachable.reachable (original_term ()),
          T.unknown (K.Standard_int_or_float.to_kind dst), r
      | Invalid ->
        Reachable.invalid (), T.bottom (K.Standard_int_or_float.to_kind dst),
          R.map_benefit r (B.remove_primitive (Unary prim))
end

module Simplify_int_conv_tagged_immediate =
  Make_simplify_int_conv (A.For_tagged_immediates)
module Simplify_int_conv_naked_float = Make_simplify_int_conv (A.For_floats)
module Simplify_int_conv_naked_int32 = Make_simplify_int_conv (A.For_int32s)
module Simplify_int_conv_naked_int64 = Make_simplify_int_conv (A.For_int64s)
module Simplify_int_conv_naked_nativeint =
  Make_simplify_int_conv (A.For_nativeints)

let simplify_boolean_not env r prim arg dbg =
  let arg, ty = S.simplify_simple env arg in
  let original_term () : Named.t = Prim (Unary (prim, arg), dbg) in
  let proof = (E.type_accessor env T.prove_tagged_immediate) ty in
  let invalid () =
    Reachable.invalid (), T.bottom (K.value Definitely_immediate),
      R.map_benefit r (B.remove_primitive (Unary prim))
  in
  match proof with
  | Proved imms ->
    let imms_ok =
      Immediate.Set.for_all (fun imm ->
          Immediate.equal imm Immediate.zero
            || Immediate.equal imm Immediate.one)
        imms
    in
    if not imms_ok then invalid ()
    else
      let imms =
        Immediate.Set.map (fun imm ->
            if Immediate.equal imm Immediate.zero then
              Immediate.one
            else
              Immediate.zero)
          imms
      in
      Reachable.reachable (original_term ()),
        T.these_tagged_immediates imms, r
  | Unknown ->
    Reachable.reachable (original_term ()),
      T.these_tagged_immediates Immediate.all_bools, r
  | Invalid -> invalid ()

let simplify_unary_float_arith_op env r prim
      (op : Flambda_primitive.unary_float_arith_op) arg dbg =
  let module F = Numbers.Float_by_bit_pattern in
  let arg, arg_ty = S.simplify_simple env arg in
  let proof = (E.type_accessor env T.prove_naked_float) arg_ty in
  let original_term () : Named.t = Prim (Unary (prim, arg), dbg) in
  let result_unknown () =
    Reachable.reachable (original_term ()), T.unknown (K.naked_float ()), r
  in
  let result_invalid () =
    Reachable.invalid (), T.bottom (K.naked_float ()),
      R.map_benefit r (B.remove_primitive (Unary prim))
  in
  match proof with
  | Proved fs when E.const_float_prop env ->
    assert (not (F.Set.is_empty fs));
    let possible_results =
      match op with
      | Abs -> F.Set.map (fun f -> F.IEEE_semantics.abs f) fs
      | Neg -> F.Set.map (fun f -> F.IEEE_semantics.neg f) fs
    in
    Reachable.reachable (original_term ()),
      T.these_naked_floats possible_results,
      r
  | Proved _ | Unknown -> result_unknown ()
  | Invalid -> result_invalid ()

let simplify_string_length env r prim arg dbg =
  let arg, arg_ty = S.simplify_simple env arg in
  let proof = (E.type_accessor env T.prove_string) arg_ty in
  let original_term () : Named.t = Prim (Unary (prim, arg), dbg) in
  let result_kind = K.value Definitely_immediate in
  let result_invalid () =
    Reachable.invalid (), T.bottom result_kind,
      R.map_benefit r (B.remove_primitive (Unary prim))
  in
  match proof with
  | Proved strs ->
    assert (T.String_info.Set.cardinal strs > 0);
    let lengths =
      T.String_info.Set.fold (fun str lengths ->
          let size = Immediate.int str.size in
          Immediate.Set.add size lengths)
        strs
        Immediate.Set.empty
    in
    Reachable.reachable (original_term ()),
      T.these_tagged_immediates lengths, r
  | Unknown ->
    Reachable.reachable (original_term ()), T.unknown result_kind, r
  | Invalid -> result_invalid ()

(* CR mshinwell: Factorize out together with [simplify_string_length] *)
(* CR mshinwell: Is it right that [block_access_kind] is unused? *)
let simplify_array_length env r prim arg ~block_access_kind:_ dbg =
  let arg, arg_ty = S.simplify_simple env arg in
  (* CR mshinwell: this may be wrong: for 32-bit platforms, arrays of floats
     have lengths differing from the lengths of the blocks
     ...hmm, but in Flambda we should only be using "logical" block
     numbering, so this may be irrelevant *)
  let proof =
    (E.type_accessor env T.prove_lengths_of_arrays_or_blocks) arg_ty
  in
  let original_term () : Named.t = Prim (Unary (prim, arg), dbg) in
  let result_kind = K.value Definitely_immediate in
  let result_invalid () =
    Reachable.invalid (), T.bottom result_kind,
      R.map_benefit r (B.remove_primitive (Unary prim))
  in
  match proof with
  | Proved lengths ->
    assert (Targetint.OCaml.Set.cardinal lengths > 0);
    let lengths =
      Targetint.OCaml.Set.fold (fun length lengths ->
          let length = Immediate.int length in
          Immediate.Set.add length lengths)
        lengths
        Immediate.Set.empty
    in
    Reachable.reachable (original_term ()),
      T.these_tagged_immediates lengths, r
  | Unknown ->
    Reachable.reachable (original_term ()), T.unknown result_kind, r
  | Invalid -> result_invalid ()

let simplify_bigarray_length env r prim bigarray ~dimension:_ dbg =
  let bigarray, bigarray_ty = S.simplify_simple env bigarray in
  let result_kind = K.value Definitely_immediate in
  let _ty_value =
    (E.type_accessor env T.prove_of_kind_value_with_expected_value_kind)
      bigarray_ty Definitely_pointer
  in
  let named : Named.t = Prim (Unary (prim, bigarray), dbg) in
  Reachable.reachable named, T.unknown result_kind, r

let simplify_unary_primitive env r (prim : Flambda_primitive.unary_primitive)
      arg dbg : Reachable.t * T.t * R.t =
  match prim with
  | Duplicate_block { kind; source_mutability;
      destination_mutability; } ->
    simplify_duplicate_block env r prim arg dbg ~kind
      ~source_mutability ~destination_mutability
  | Is_int -> simplify_is_int env r prim arg dbg
  | Get_tag { tags_to_sizes; } ->
    simplify_get_tag env r  prim ~tags_to_sizes ~block:arg dbg
  | String_length _string_or_bytes ->
    simplify_string_length env r prim arg dbg
  | Int_as_pointer ->
    let arg, _arg_ty = S.simplify_simple env arg in
    Reachable.reachable (Prim (Unary (prim, arg), dbg)),
      T.unknown (K.value Unknown), r
  | Opaque_identity ->
    let arg, arg_ty = S.simplify_simple env arg in
    let kind = (E.type_accessor env T.kind) arg_ty in
    Reachable.reachable (Prim (Unary (prim, arg), dbg)),
      T.unknown kind, r
  | Int_arith (kind, op) ->
    begin match kind with
    | Tagged_immediate ->
      Unary_int_arith_tagged_immediate.simplify env r prim dbg op arg
    | Naked_int32 ->
      Unary_int_arith_naked_int32.simplify env r prim dbg op arg
    | Naked_int64 ->
      Unary_int_arith_naked_int64.simplify env r prim dbg op arg
    | Naked_nativeint ->
      Unary_int_arith_naked_nativeint.simplify env r prim dbg op arg
    end
  | Num_conv { src = Tagged_immediate; dst; } ->
    Simplify_int_conv_tagged_immediate.simplify env r prim arg ~dst dbg
  | Num_conv { src = Naked_float; dst; } ->
    Simplify_int_conv_naked_float.simplify env r prim arg ~dst dbg
  | Num_conv { src = Naked_int32; dst; } ->
    Simplify_int_conv_naked_int32.simplify env r prim arg ~dst dbg
  | Num_conv { src = Naked_int64; dst; } ->
    Simplify_int_conv_naked_int64.simplify env r prim arg ~dst dbg
  | Num_conv { src = Naked_nativeint; dst; } ->
    Simplify_int_conv_naked_nativeint.simplify env r prim arg ~dst dbg
  | Boolean_not ->
    simplify_boolean_not env r prim arg dbg
  | Float_arith op -> simplify_unary_float_arith_op env r prim op arg dbg
  | Array_length block_access_kind ->
    simplify_array_length env r prim arg ~block_access_kind dbg
  | Bigarray_length { dimension : int; } ->
    simplify_bigarray_length env r prim arg ~dimension dbg
  | Unbox_number Naked_float ->
    Simplify_unbox_number_float.simplify env r prim arg dbg
  | Unbox_number Naked_int32 ->
    Simplify_unbox_number_int32.simplify env r prim arg dbg
  | Unbox_number Naked_int64 ->
    Simplify_unbox_number_int64.simplify env r prim arg dbg
  | Unbox_number Naked_nativeint ->
    Simplify_unbox_number_nativeint.simplify env r prim arg dbg
  | Box_number Naked_float ->
    Simplify_box_number_float.simplify env r prim arg dbg
  | Box_number Naked_int32 ->
    Simplify_box_number_int32.simplify env r prim arg dbg
  | Box_number Naked_int64 ->
    Simplify_box_number_int64.simplify env r prim arg dbg
  | Box_number Naked_nativeint ->
    Simplify_box_number_nativeint.simplify env r prim arg dbg
  | Project_closure closure ->
    simplify_project_closure env r prim ~closure ~set_of_closures:arg dbg
  | Move_within_set_of_closures { move_from; move_to; } ->
    simplify_move_within_set_of_closures env r prim ~move_from ~move_to
      ~closure:arg dbg
  | Project_var (closure_id, var_within_closure) ->
    simplify_project_var env r prim ~closure_id ~var_within_closure
      ~closure:arg dbg
