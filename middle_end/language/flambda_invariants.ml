(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                       Pierre Chambart, OCamlPro                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2013--2016 OCamlPro SAS                                    *)
(*   Copyright 2014--2016 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

[@@@ocaml.warning "+a-4-30-40-41-42"]

type normal_or_lifted =
  | Normal
  | Lifted

(* CR mshinwell: Check that apply_cont is well-formed when there is a
   trap installation or removal. *)

(* Explicit "ignore" functions.  We name every pattern variable, avoiding
   underscores, to try to avoid accidentally failing to handle (for example)
   a particular variable.
   We also avoid explicit record field access during the checking functions,
   preferring instead to use exhaustive record matches.
*)
(* CR-someday pchambart: for sum types, we should probably add an exhaustive
   pattern in ignores functions to be reminded if a type change *)
let ignore_call_kind (_ : Flambda.Call_kind.t) = ()
let ignore_debuginfo (_ : Debuginfo.t) = ()
let ignore_meth_kind (_ : Lambda.meth_kind) = ()
let ignore_targetint (_ : Targetint.t) = ()
let ignore_targetint_set (_ : Targetint.Set.t) = ()
let ignore_bool (_ : bool) = ()
let ignore_continuation (_ : Continuation.t) = ()
let ignore_primitive ( _ : Lambda.primitive) = ()
let ignore_const (_ : Flambda.Const.t) = ()
let ignore_immediate (_ : Immediate.t) = ()
let ignore_allocated_const (_ : Allocated_const.t) = ()
let ignore_flambda_kind (_ : Flambda_kind.t) = ()
let ignore_flambda_arity (_ : Flambda_arity.t) = ()
let ignore_set_of_closures_id (_ : Set_of_closures_id.t) = ()
let ignore_set_of_closures_origin (_ : Set_of_closures_origin.t) = ()
let ignore_closure_id (_ : Closure_id.t) = ()
let ignore_closure_id_set (_ : Closure_id.Set.t) = ()
let ignore_closure_id_map (_ : 'a -> unit) (_ : 'a Closure_id.Map.t) = ()
let ignore_var_within_closure (_ : Var_within_closure.t) = ()
let ignore_tag (_ : Tag.t) = ()
let ignore_scannable_tag (_ : Tag.Scannable.t) = ()
let ignore_inline_attribute (_ : Lambda.inline_attribute) = ()
let ignore_specialise_attribute (_ : Lambda.specialise_attribute) = ()

exception Binding_occurrence_not_from_current_compilation_unit of Variable.t
exception Mutable_binding_occurrence_not_from_current_compilation_unit of
  Mutable_variable.t
exception Binding_occurrence_of_variable_already_bound of Variable.t
exception Binding_occurrence_of_mutable_variable_already_bound of
  Mutable_variable.t
exception Binding_occurrence_of_symbol_already_bound of Symbol.t
exception Unbound_variable of Variable.t
exception Unbound_mutable_variable of Mutable_variable.t
exception Unbound_symbol of Symbol.t
exception Bad_free_vars_in_function_body of
  Variable.Set.t * Flambda.Set_of_closures.t * Closure_id.t
exception Function_decls_have_overlapping_parameters of Variable.Set.t
exception Projection_must_be_a_free_var of Projection.t
exception Projection_must_be_a_parameter of Projection.t
exception Continuation_not_caught of Continuation.t * string
exception Continuation_called_with_wrong_arity of
  Continuation.t * Flambda_arity.t * Flambda_arity.t
exception Malformed_exception_continuation of Continuation.t * string
exception Access_to_global_module_identifier of Lambda.primitive
exception Pidentity_should_not_occur
exception Pdirapply_should_be_expanded
exception Prevapply_should_be_expanded
exception Ploc_should_be_expanded
exception Sequential_logical_operator_primitives_must_be_expanded of
  Lambda.primitive
exception Declared_closure_from_another_unit of Compilation_unit.t
exception Set_of_closures_id_is_bound_multiple_times of Set_of_closures_id.t
exception Unbound_closure_ids of Closure_id.Set.t
exception Unbound_vars_within_closures of Var_within_closure.Set.t
exception Exception_handler_used_as_normal_continuation of Continuation.t
exception Exception_handler_used_as_return_continuation of Continuation.t
exception Normal_continuation_used_as_exception_handler of Continuation.t
exception Empty_switch of Variable.t

exception Flambda_invariants_failed

(* CR-someday mshinwell: We should make "direct applications should not have
  overapplication" be an invariant throughout.  At the moment I think this is
  only true after [Simplify] has split overapplications. *)

(* CR-someday mshinwell: What about checks for shadowed variables and
  symbols? *)

module Push_pop_invariants = struct
  type stack_t =
    | Root
    | Var (* Debug *)
    | Link of stack_type
    | Push of Trap_id.t * Continuation.t * stack_type

  and stack_type = stack_t ref

  type env = stack_type Continuation.Map.t

  let rec repr t =
    match !t with
    | Link s ->
      let u = repr s in
      t := u;
      u
    | v -> v

  let rec occur_check cont t checked =
    if t == checked then
      raise (Malformed_exception_continuation (cont, "recursive stack"));
    match !checked with
    | Var
    | Root -> ()
    | Link s
    | Push (_, _, s) ->
      occur_check cont t s

  let rec unify_stack cont t1 t2 =
    if t1 == t2 then ()
    else
      match repr t1, repr t2 with
      | Link _, _ | _, Link _ -> assert false
      | Var, _ ->
        occur_check cont t1 t2;
        t1 := Link t2
      | _, Var ->
        occur_check cont t2 t1;
        t2 := Link t1
      | Root, Root -> ()
      | Push (id1, c1, s1), Push (id2, c2, s2) ->
        if not (Trap_id.equal id1 id2) then
          raise (Malformed_exception_continuation (cont, "mismatched trap id"));
        if not (Continuation.equal c1 c2) then begin
          let msg =
            Format.asprintf "%a versus %a"
              Continuation.print c1
              Continuation.print c2
          in
          raise (Malformed_exception_continuation (cont,
            "mismatched continuations: " ^ msg))
        end;
        unify_stack cont s1 s2
      | Root, Push _ | Push _, Root ->
        raise (Malformed_exception_continuation (cont, "root stack is not empty"))

  let var () =
    ref (Var)

  let push id cont s =
    ref (Push(id, cont, s))

  let define table k stack =
    if Continuation.Map.mem k table then begin
      Misc.fatal_errorf "Multiple definitions of continuation %a"
        Continuation.print k
    end;
    Continuation.Map.add k stack table

  let rec loop (env:env) current_stack (expr : Flambda.Expr.t) =
    match expr with
    | Let { body; _ } | Let_mutable { body; _ } -> loop env current_stack body
    | Let_cont { body; handlers; } ->
      let handler_stack = var () in
      let env =
        match handlers with
        | Nonrecursive { name; handler; } ->
          loop env handler_stack handler.handler;
          define env name handler_stack
        | Recursive handlers ->
          let recursive_env =
            Continuation.Map.fold (fun cont _handler env ->
                define env cont handler_stack)
              handlers
              env
          in
          Continuation.Map.iter (fun _cont
                  (handler : Flambda.Continuation_handler.t) ->
              loop recursive_env handler_stack handler.handler)
            handlers;
          Continuation.Map.fold (fun cont _handler env ->
              define env cont handler_stack)
            handlers
            env
      in
      loop env current_stack body
    | Apply_cont ( cont, exn, _args ) ->
      let cont_stack =
        match Continuation.Map.find cont env with
        | exception Not_found ->
          Misc.fatal_errorf "Unbound continuation %a in Apply_cont %a"
            Continuation.print cont
            Flambda.Expr.print expr
        | cont_stack -> cont_stack
      in
      let stack, cont_stack =
        match exn with
        | None ->
          current_stack,
          cont_stack
        | Some (Push { id; exn_handler }) ->
          push id exn_handler current_stack,
          cont_stack
        | Some (Pop { id; exn_handler }) ->
          current_stack,
          push id exn_handler cont_stack
      in
      unify_stack cont stack cont_stack
    | Apply { continuation; _ } ->
      let stack = current_stack in
      let cont_stack =
        match Continuation.Map.find continuation env with
        | exception Not_found ->
          Misc.fatal_errorf "Unbound continuation %a in application %a"
            Continuation.print continuation
            Flambda.Expr.print expr
        | cont_stack -> cont_stack
      in
      unify_stack continuation stack cont_stack
    | Switch (_,{ consts; failaction; _ } ) ->
      List.iter (fun (_, cont) ->
        let cont_stack =
          match Continuation.Map.find cont env with
          | exception Not_found ->
            Misc.fatal_errorf "Unbound continuation %a in switch %a"
              Continuation.print cont
              Flambda.Expr.print expr
          | cont_stack -> cont_stack
        in
        unify_stack cont cont_stack current_stack)
        consts;
      begin match failaction with
      | None -> ()
      | Some cont ->
        let cont_stack =
          match Continuation.Map.find cont env with
          | exception Not_found ->
            Misc.fatal_errorf "Unbound continuation %a in switch %a"
              Continuation.print cont
              Flambda.Expr.print expr
          | cont_stack -> cont_stack
        in
        unify_stack cont cont_stack current_stack
      end
    | Unreachable -> ()

  and well_formed_trap ~continuation_arity:_ k (expr : Flambda.Expr.t) =
    let root = ref Root in
    let env = Continuation.Map.singleton k root in
    loop env root expr

  let check program =
    Flambda_static.Program.Iterators.iter_toplevel_exprs program
      ~f:well_formed_trap
end

module Continuation_scoping = struct
  type kind = Normal | Exn_handler

  type env = {
    continuations : (Flambda_arity.t * kind) Continuation.Map.t;
    variables : Flambda_kind.t Variable.Map.t;
  }

  let add_variable env var kind =
    if Variable.Map.mem var env.variables then begin
      Misc.fatal_errorf "Duplicate binding of variable %a" Variable.print var
    end;
    { env with
      variables = Variable.Map.add var kind env.variables;
    }

  let add_continuation env cont arity kind =
    if Continuation.Map.mem cont env.continuations then begin
      Misc.fatal_errorf "Duplicate binding of continuation %a"
        Continuation.print cont
    end;
    { env with
      continuations = Continuation.Map.add cont (arity, kind) env.continuations;
    }

  let add_typed_parameters ~importer env params =
    List.fold_left (fun env param ->
        let var = Flambda.Typed_parameter.var param in
        let kind = Flambda.Typed_parameter.kind ~importer param in
        add_variable env var kind)
      env
      params

  let rec loop ~importer env (expr : Flambda.Expr.t) =
    match expr with
    | Let { var; kind; body; _ } ->
      let env = add_variable env var kind in
      loop ~importer env body
    | Let_mutable { body; _ } -> loop ~importer env body
    | Let_cont { body; handlers; } ->
      let env =
        match handlers with
        | Nonrecursive { name; handler; } ->
          let kind = if handler.is_exn_handler then Exn_handler else Normal in
          let params = handler.params in
          let arity = Flambda.Typed_parameter.List.arity ~importer params in
          let env = add_typed_parameters ~importer env params in
          loop ~importer env handler.handler;
          add_continuation env name arity kind
        | Recursive handlers ->
          let recursive_env =
            Continuation.Map.fold (fun cont
                    (handler : Flambda.Continuation_handler.t) env ->
                let arity =
                  Flambda.Typed_parameter.List.arity ~importer handler.params
                in
                let kind =
                  if handler.is_exn_handler then Exn_handler else Normal
                in
                add_continuation env cont arity kind)
              handlers
              env
          in
          Continuation.Map.iter (fun name
                  ({ params; stub; is_exn_handler; handler; }
                    : Flambda.Continuation_handler.t) ->
              ignore_continuation name;
              let env = add_typed_parameters ~importer recursive_env params in
              loop ~importer env handler;
              ignore_bool stub;
              ignore_bool is_exn_handler)
            handlers;
          Continuation.Map.fold (fun cont
                  (handler : Flambda.Continuation_handler.t) env ->
              let arity =
                Flambda.Typed_parameter.List.arity ~importer handler.params
              in
              let kind =
                if handler.is_exn_handler then Exn_handler else Normal
              in
              add_continuation env cont arity kind)
            handlers
            env
      in
      loop ~importer env body
    | Apply_cont (cont, exn, args) ->
      let args_arity =
        List.map (fun arg ->
            match Variable.Map.find arg env.variables with
            | kind -> kind
            | exception Not_found ->
              Misc.fatal_errorf "Unbound variable %a" Variable.print arg)
          args
      in
      let arity, kind =
        try Continuation.Map.find cont env.continuations
        with Not_found -> raise (Continuation_not_caught (cont, "apply_cont"))
      in
      if not (Flambda_arity.equal args_arity arity) then begin
        raise (Continuation_called_with_wrong_arity (cont, args_arity, arity))
      end;
      begin match kind with
      | Normal -> ()
      | Exn_handler ->
        raise (Exception_handler_used_as_normal_continuation cont)
      end;
      begin match exn with
      | None -> ()
      | Some (Push { id = _; exn_handler })
      | Some (Pop { id = _; exn_handler }) ->
        match Continuation.Map.find exn_handler env.continuations with
        | exception Not_found ->
          raise (Continuation_not_caught (exn_handler, "push/pop"))
        | (arity, kind) ->
          begin match kind with
          | Exn_handler -> ()
          | Normal ->
            raise (Normal_continuation_used_as_exception_handler exn_handler)
          end;
          assert (not (Continuation.equal cont exn_handler));
          let expected = [Flambda_kind.value Must_scan] in
          if not (Flambda_arity.equal arity expected) then begin
            raise (Continuation_called_with_wrong_arity (cont, expected, arity))
          end
      end
    | Apply { continuation; call_kind; _ } ->
      begin match Continuation.Map.find continuation env.continuations with
      | exception Not_found ->
        raise (Continuation_not_caught (continuation, "apply"))
      | arity, kind ->
        begin match kind with
        | Normal -> ()
        | Exn_handler ->
          raise (Exception_handler_used_as_return_continuation continuation)
        end;
        let expected_arity = Flambda.Call_kind.return_arity call_kind in
        if not (Flambda_arity.equal arity expected_arity) then begin
          raise (Continuation_called_with_wrong_arity
            (continuation, expected_arity, arity))
        end
      end
    | Switch (_,{ consts; failaction; _ } ) ->
      let check (_, cont) =
        match Continuation.Map.find cont env.continuations with
        | exception Not_found ->
          raise (Continuation_not_caught (cont, "switch"))
        | arity, kind ->
          begin match kind with
          | Normal -> ()
          | Exn_handler ->
            raise (Exception_handler_used_as_normal_continuation cont)
          end;
          if List.length arity <> 0 then begin
            raise (Continuation_called_with_wrong_arity (cont, [], arity))
          end
      in
      List.iter check consts;
      begin match failaction with
      | None -> ()
      | Some cont -> check ((), cont)
      end
    | Unreachable -> ()

  and check_expr ~importer ~continuation_arity k (expr : Flambda.Expr.t) =
    let env =
      { continuations =
          Continuation.Map.singleton k (continuation_arity, Normal);
        variables = Variable.Map.empty;
      }
    in
    loop ~importer env expr

  let check ~importer program =
    Flambda_static.Program.Iterators.iter_toplevel_exprs program
      ~f:(check_expr ~importer)
end

let variable_and_symbol_invariants (program : Flambda_static.Program.t) =
  let all_declared_variables = ref Variable.Set.empty in
  let declare_variable var =
    if Variable.Set.mem var !all_declared_variables then
      raise (Binding_occurrence_of_variable_already_bound var);
    all_declared_variables := Variable.Set.add var !all_declared_variables
  in
  let declare_variables vars =
    Variable.Set.iter declare_variable vars
  in
  let all_declared_mutable_variables = ref Mutable_variable.Set.empty in
  let declare_mutable_variable mut_var =
    if Mutable_variable.Set.mem mut_var !all_declared_mutable_variables then
      raise (Binding_occurrence_of_mutable_variable_already_bound mut_var);
    all_declared_mutable_variables :=
      Mutable_variable.Set.add mut_var !all_declared_mutable_variables
  in
  let add_binding_occurrence (var_env, mut_var_env, sym_env) var =
    let compilation_unit = Compilation_unit.get_current_exn () in
    if not (Variable.in_compilation_unit var compilation_unit) then
      raise (Binding_occurrence_not_from_current_compilation_unit var);
    declare_variable var;
    Variable.Set.add var var_env, mut_var_env, sym_env
  in
  let add_mutable_binding_occurrence (var_env, mut_var_env, sym_env) mut_var =
    let compilation_unit = Compilation_unit.get_current_exn () in
    if not (Mutable_variable.in_compilation_unit mut_var compilation_unit) then
      raise (Mutable_binding_occurrence_not_from_current_compilation_unit
        mut_var);
    declare_mutable_variable mut_var;
    var_env, Mutable_variable.Set.add mut_var mut_var_env, sym_env
  in
  let add_binding_occurrence_of_symbol (var_env, mut_var_env, sym_env) sym =
    if Symbol.Set.mem sym sym_env then
      raise (Binding_occurrence_of_symbol_already_bound sym)
    else
      var_env, mut_var_env, Symbol.Set.add sym sym_env
  in
  let add_binding_occurrences env vars =
    List.fold_left (fun env var -> add_binding_occurrence env var) env vars
  in
  let check_variable_is_bound (var_env, _, _) var =
    if not (Variable.Set.mem var var_env) then raise (Unbound_variable var)
  in
  let check_symbol_is_bound (_, _, sym_env) sym =
    if not (Symbol.Set.mem sym sym_env) then raise (Unbound_symbol sym)
  in
  let check_variables_are_bound env vars =
    List.iter (check_variable_is_bound env) vars
  in
  let check_mutable_variable_is_bound (_, mut_var_env, _) mut_var =
    if not (Mutable_variable.Set.mem mut_var mut_var_env) then begin
      raise (Unbound_mutable_variable mut_var)
    end
  in
  let rec loop env (flam : Flambda.Expr.t) =
    match flam with
    (* Expressions that can bind [Variable.t]s: *)
    | Let { var; defining_expr; body; _ } ->
      loop_named env defining_expr;
      loop (add_binding_occurrence env var) body
    | Let_mutable { var = mut_var; initial_value = var;
                    body; contents_kind } ->
      ignore_flambda_kind contents_kind;
      check_variable_is_bound env var;
      loop (add_mutable_binding_occurrence env mut_var) body
    | Let_cont { body; handlers; } ->
      loop env body;
      begin match handlers with
      | Nonrecursive { name; handler = {
          params; stub; is_exn_handler; handler; }; } ->
        ignore_continuation name;
        ignore_bool stub;
        ignore_bool is_exn_handler;
        let params = Flambda.Typed_parameter.List.vars params in
        loop (add_binding_occurrences env params) handler
      | Recursive handlers ->
        Continuation.Map.iter (fun name
                ({ params; stub; is_exn_handler; handler; }
                  : Flambda.Continuation_handler.t) ->
            ignore_bool stub;
            if is_exn_handler then begin
              Misc.fatal_errorf "Continuation %a is declared [Recursive] but \
                  is an exception handler"
                Continuation.print name
            end;
            let params = Flambda.Typed_parameter.List.vars params in
            loop (add_binding_occurrences env params) handler)
          handlers
      end
    (* Everything else: *)
    | Apply { kind = Function; func; continuation; args; call_kind; dbg; inline;
        specialise; } ->
      check_variable_is_bound env func;
      check_variables_are_bound env args;
      (* CR mshinwell: check continuations are bound *)
      ignore_continuation continuation;
      ignore_call_kind call_kind;
      ignore_debuginfo dbg;
      ignore_inline_attribute inline;
      ignore_specialise_attribute specialise
    | Apply { kind = Method { kind; obj; }; func; continuation; args; call_kind;
        dbg; inline; specialise; } ->
      ignore_meth_kind kind;
      check_variable_is_bound env obj;
      check_variable_is_bound env func;
      check_variables_are_bound env args;
      ignore_continuation continuation;
      ignore_call_kind call_kind;
      ignore_debuginfo dbg;
      ignore_inline_attribute inline;
      ignore_specialise_attribute specialise
    | Switch (arg, { numconsts; consts; failaction; }) ->
      if List.length consts < 1 then begin
        raise (Empty_switch arg)
      end;
      check_variable_is_bound env arg;
      ignore_targetint_set numconsts;
      List.iter (fun (n, e) ->
          ignore_targetint n;
          ignore_continuation e)
        consts;
      Misc.may ignore_continuation failaction
    | Apply_cont (static_exn, trap_action, es) ->
      begin match trap_action with
      | None -> ()
      | Some (Push { id = _; exn_handler; })
      | Some (Pop { id = _; exn_handler; }) -> ignore_continuation exn_handler
      end;
      ignore_continuation static_exn;
      List.iter (check_variable_is_bound env) es
    | Unreachable -> ()
  and loop_named env (named : Flambda.Named.t) =
    match named with
    | Var var -> check_variable_is_bound env var
    | Symbol symbol ->
      let symbol = Symbol.Of_kind_value.to_symbol symbol in
      check_symbol_is_bound env symbol
    | Const const -> ignore_const const
    | Allocated_const const -> ignore_allocated_const const
    | Read_mutable mut_var ->
      check_mutable_variable_is_bound env mut_var
    | Assign { being_assigned; new_value; } ->
      check_mutable_variable_is_bound env being_assigned;
      check_variable_is_bound env new_value
    | Read_symbol_field { symbol; logical_field; } ->
      check_symbol_is_bound env symbol;
      assert (logical_field >= 0)  (* CR-someday mshinwell: add proper error *)
    | Set_of_closures set_of_closures ->
      loop_set_of_closures env set_of_closures
    | Project_closure { set_of_closures; closure_id; } ->
      check_variable_is_bound env set_of_closures;
      ignore_closure_id_set closure_id
    | Move_within_set_of_closures { closure; move } ->
      check_variable_is_bound env closure;
      ignore_closure_id_map ignore_closure_id move
    | Project_var { closure; var; } ->
      check_variable_is_bound env closure;
      ignore_closure_id_map ignore_var_within_closure var;
    | Prim (prim, args, dbg) ->
      ignore_primitive prim;
      check_variables_are_bound env args;
      ignore_debuginfo dbg
  and loop_set_of_closures env
      ({ Flambda.Set_of_closures. function_decls; free_vars;
          direct_call_surrogates = _; } as set_of_closures) =
      (* CR-soon mshinwell: check [direct_call_surrogates] *)
      let { Flambda.Function_declarations. set_of_closures_id;
            set_of_closures_origin; funs; } =
        function_decls
      in
      ignore_set_of_closures_id set_of_closures_id;
      ignore_set_of_closures_origin set_of_closures_origin;
      let functions_in_closure = Closure_id.Map.keys funs in
      Var_within_closure.Map.iter
        (fun var (var_in_closure : Flambda.Free_var.t) ->
          ignore_var_within_closure var;
          check_variable_is_bound env var_in_closure.var)
        free_vars;
      let _all_params, _all_free_vars =
        (* CR mshinwell: change to [iter] *)
        Closure_id.Map.fold (fun fun_var function_decl acc ->
            let all_params, all_free_vars = acc in
            (* CR-soon mshinwell: check function_decl.all_symbols *)
            let { Flambda.Function_declaration.params; body; stub; dbg;
                  my_closure; _ } =
              function_decl
            in
            assert (Closure_id.Set.mem fun_var functions_in_closure);
            ignore_bool stub;
            ignore_debuginfo dbg;
            let free_variables = Flambda.Expr.free_variables body in
            (* Check that every variable free in the body of the function is
               either the distinguished "own closure" variable or one of the
               function's parameters. *)
            let acceptable_free_variables =
              Variable.Set.add my_closure
                (Flambda.Typed_parameter.List.var_set params)
            in
            let bad =
              Variable.Set.diff free_variables acceptable_free_variables
            in
            if not (Variable.Set.is_empty bad) then begin
              raise (Bad_free_vars_in_function_body
                (bad, set_of_closures, fun_var))
            end;
            (* Check that free variables in parameters' types are bound. *)
            List.iter (fun param ->
                let ty = Flambda.Typed_parameter.ty param in
                let fvs = Flambda_type.free_variables ty in
                Variable.Set.iter (fun fv -> check_variable_is_bound env fv)
                  fvs)
              params;
            (* Check that projections on parameters only describe projections
               from other parameters of the same function. *)
            let params' = Flambda.Typed_parameter.List.var_set params in
            List.iter (fun param ->
                match Flambda.Typed_parameter.projection param with
                | None -> ()
                | Some projection ->
                  let projecting_from = Projection.projecting_from projection in
                  if not (Variable.Set.mem projecting_from params') then begin 
                    raise (Projection_must_be_a_parameter projection)
                  end)
              params;
            (* Check that parameters are unique across all functions in the
               declaration. *)
            let old_all_params_size = Variable.Set.cardinal all_params in
            let params = params' in
            let params_size = Variable.Set.cardinal params in
            let all_params = Variable.Set.union all_params params in
            let all_params_size = Variable.Set.cardinal all_params in
            if all_params_size <> old_all_params_size + params_size then begin
              raise (Function_decls_have_overlapping_parameters all_params)
            end;
            (* Check that parameters are not bound somewhere else in the
               program.  (Note that the closure ID, [fun_var], may be bound
               by multiple sets of closures.) *)
            declare_variables params;
            (* Check that the body of the functions is correctly structured *)
            let body_env =
              let (var_env, _, sym_env) = env in
              let var_env =
                Variable.Set.fold (fun var -> Variable.Set.add var)
                  free_variables var_env
              in
              (* Mutable variables cannot be captured by closures *)
              let mut_env = Mutable_variable.Set.empty in
              (var_env, mut_env, sym_env)
            in
            loop body_env body;
            all_params, Variable.Set.union free_variables all_free_vars)
          funs (Variable.Set.empty, Variable.Set.empty)
      in
      Var_within_closure.Map.iter
        (fun _in_closure (outer_var : Flambda.Free_var.t) ->
          check_variable_is_bound env outer_var.var;
          match outer_var.projection with
          | None -> ()
          | Some projection ->
            let projecting_from = Projection.projecting_from projection in
            let in_closure =
              Flambda.Free_vars.find_by_variable free_vars projecting_from
            in
            match in_closure with
            | None ->
              (* CR mshinwell: bad exception name? *)
              raise (Projection_must_be_a_free_var projection)
            | Some _in_closure -> ())
        free_vars
  in
  let loop_constant_defining_value env
        (const : Flambda_static.Constant_defining_value.t) =
    match const with
    | Allocated_const c ->
      ignore_allocated_const c
    | Block (tag, fields) ->
      ignore_scannable_tag tag;
      List.iter
        (fun (fields : Flambda_static.Constant_defining_value_block_field.t) ->
          match fields with
          | Tagged_immediate i -> ignore_immediate i
          | Symbol s -> check_symbol_is_bound env s)
        fields
    | Set_of_closures set_of_closures ->
      loop_set_of_closures env set_of_closures;
      (* Constant sets of closures must not have free variables.  This should
         be enforced by an abstract type boundary (see [Flambda_static0]), so
         we just [assert false] if this fails. *)
      if not (Var_within_closure.Map.is_empty set_of_closures.free_vars) then
      begin
        assert false
      end
    | Project_closure (symbol, closure_id) ->
      ignore_closure_id closure_id;
      check_symbol_is_bound env symbol
  in
  let rec loop_program_body env (program : Flambda_static.Program_body.t) =
    match program with
    | Let_rec_symbol (defs, program) ->
      let env =
        List.fold_left (fun env (symbol, _) ->
            add_binding_occurrence_of_symbol env symbol)
          env defs
      in
      List.iter (fun (_, def) ->
          loop_constant_defining_value env def)
        defs;
      loop_program_body env program
    | Let_symbol (symbol, def, program) ->
      loop_constant_defining_value env def;
      let env = add_binding_occurrence_of_symbol env symbol in
      loop_program_body env program
    | Initialize_symbol (symbol, descr, program) ->
      let { Flambda_static.Program_body.Initialize_symbol.
            tag; expr; return_cont; return_arity; } = descr
      in
      ignore_tag tag;
      loop env expr;
      ignore_continuation return_cont;
      ignore_flambda_arity return_arity;
      let env = add_binding_occurrence_of_symbol env symbol in
      loop_program_body env program
    | Effect (expr, cont, program) ->
      loop env expr;
      ignore_continuation cont;
      loop_program_body env program
    | End root ->
      check_symbol_is_bound env root
  in
  let env =
    Symbol.Set.fold (fun symbol env ->
        add_binding_occurrence_of_symbol env symbol)
      program.imported_symbols
      (Variable.Set.empty, Mutable_variable.Set.empty, Symbol.Set.empty)
  in
  loop_program_body env program.program_body

let primitive_invariants flam ~no_access_to_global_module_identifiers =
  Flambda.Expr.Iterators.iter_named (function
      | Prim (prim, _, _) ->
        begin match prim with
        | Psequand | Psequor ->
          raise (Sequential_logical_operator_primitives_must_be_expanded prim)
        | Pgetglobal id ->
          if no_access_to_global_module_identifiers
            && not (Ident.is_predef_exn id) then
          begin
            raise (Access_to_global_module_identifier prim)
          end
        | Pidentity -> raise Pidentity_should_not_occur
        | Pdirapply -> raise Pdirapply_should_be_expanded
        | Prevapply -> raise Prevapply_should_be_expanded
        | Ploc _ -> raise Ploc_should_be_expanded
        | _ -> ()
        end
      | _ -> ())
    flam

let declared_var_within_closure (flam : Flambda_static.Program.t) =
  let bound = ref Var_within_closure.Set.empty in
  Flambda_static.Program.Iterators.iter_set_of_closures flam
    ~f:(fun ~constant:_ { Flambda.Set_of_closures. free_vars; _ } ->
      Var_within_closure.Map.iter (fun in_closure _ ->
          bound := Var_within_closure.Set.add in_closure !bound)
        free_vars);
  !bound

let every_declared_closure_is_from_current_compilation_unit flam =
  let current_compilation_unit = Compilation_unit.get_current_exn () in
  Flambda.Expr.Iterators.iter_sets_of_closures
    (fun { Flambda.Set_of_closures. function_decls; _ } ->
      let compilation_unit =
        Set_of_closures_id.get_compilation_unit
          function_decls.set_of_closures_id
      in
      if not (Compilation_unit.equal compilation_unit current_compilation_unit)
      then raise (Declared_closure_from_another_unit compilation_unit))
    flam

let declared_closure_ids program =
  let bound = ref Closure_id.Set.empty in
  Flambda_static.Program.Iterators.iter_set_of_closures program
    ~f:(fun ~constant:_ { Flambda.Set_of_closures. function_decls; _; } ->
      Closure_id.Map.iter (fun closure_id _ ->
          bound := Closure_id.Set.add closure_id !bound)
        function_decls.funs);
  !bound

let declared_set_of_closures_ids program =
  let bound = ref Set_of_closures_id.Set.empty in
  let bound_multiple_times = ref None in
  let add_and_check var =
    if Set_of_closures_id.Set.mem var !bound
    then bound_multiple_times := Some var;
    bound := Set_of_closures_id.Set.add var !bound
  in
  Flambda_static.Program.Iterators.iter_set_of_closures program
    ~f:(fun ~constant:_ { Flambda.Set_of_closures. function_decls; _; } ->
        add_and_check function_decls.set_of_closures_id);
  !bound, !bound_multiple_times

let no_set_of_closures_id_is_bound_multiple_times program =
  match declared_set_of_closures_ids program with
  | _, Some set_of_closures_id ->
    raise (Set_of_closures_id_is_bound_multiple_times set_of_closures_id)
  | _, None -> ()

let used_closure_ids (program:Flambda_static.Program.t) =
  let used = ref Closure_id.Set.empty in
  let f (flam : Flambda.Named.t) =
    match flam with
    | Project_closure { closure_id; _} ->
      used := Closure_id.Set.union closure_id !used;
    | Move_within_set_of_closures { closure = _; move; } ->
      Closure_id.Map.iter (fun start_from move_to ->
        used := Closure_id.Set.add start_from !used;
        used := Closure_id.Set.add move_to !used)
        move
    | Project_var { closure = _; var } ->
      used := Closure_id.Set.union (Closure_id.Map.keys var) !used
    | Set_of_closures _ | Var _ | Symbol _ | Const _ | Allocated_const _
    | Prim _ | Assign _ | Read_mutable _ | Read_symbol_field _ -> ()
  in
  (* CR-someday pchambart: check closure_ids of constant_defining_values'
    project_closures *)
  Flambda_static.Program.Iterators.iter_named ~f program;
  !used

let used_vars_within_closures (flam:Flambda_static.Program.t) =
  let used = ref Var_within_closure.Set.empty in
  let f (flam : Flambda.Named.t) =
    match flam with
    | Project_var { closure = _; var; } ->
      Closure_id.Map.iter (fun _ var ->
        used := Var_within_closure.Set.add var !used)
        var
    | _ -> ()
  in
  Flambda_static.Program.Iterators.iter_named ~f flam;
  !used

let every_used_function_from_current_compilation_unit_is_declared
      (program : Flambda_static.Program.t) =
  let current_compilation_unit = Compilation_unit.get_current_exn () in
  let declared = declared_closure_ids program in
  let used = used_closure_ids program in
  let used_from_current_unit =
    Closure_id.Set.filter (fun cu ->
        Closure_id.in_compilation_unit cu current_compilation_unit)
      used
  in
  let counter_examples =
    Closure_id.Set.diff used_from_current_unit declared
  in
  if Closure_id.Set.is_empty counter_examples
  then ()
  else raise (Unbound_closure_ids counter_examples)

let every_used_var_within_closure_from_current_compilation_unit_is_declared
      (flam:Flambda_static.Program.t) =
  let current_compilation_unit = Compilation_unit.get_current_exn () in
  let declared = declared_var_within_closure flam in
  let used = used_vars_within_closures flam in
  let used_from_current_unit =
    Var_within_closure.Set.filter (fun cu ->
        Var_within_closure.in_compilation_unit cu current_compilation_unit)
      used
  in
  let counter_examples =
    Var_within_closure.Set.diff used_from_current_unit declared in
  if Var_within_closure.Set.is_empty counter_examples
  then ()
  else raise (Unbound_vars_within_closures counter_examples)

let check_exn ~importer ?(kind = Normal) ?(cmxfile = false)
      (flam : Flambda_static.Program.t) =
  ignore kind;
  try
    variable_and_symbol_invariants flam;
    no_set_of_closures_id_is_bound_multiple_times flam;
    every_used_function_from_current_compilation_unit_is_declared flam;
    every_used_var_within_closure_from_current_compilation_unit_is_declared
      flam;
    Flambda_static.Program.Iterators.iter_toplevel_exprs flam
      ~f:(fun ~continuation_arity:_ _cont flam ->
        primitive_invariants flam
          ~no_access_to_global_module_identifiers:cmxfile;
        every_declared_closure_is_from_current_compilation_unit flam);
    Push_pop_invariants.check flam;
    Continuation_scoping.check ~importer flam
  with exn -> begin
  (* CR-someday split printing code into its own function *)
    begin match exn with
    | Binding_occurrence_not_from_current_compilation_unit var ->
      Format.eprintf ">> Binding occurrence of variable marked as not being \
          from the current compilation unit: %a"
        Variable.print var
    | Mutable_binding_occurrence_not_from_current_compilation_unit mut_var ->
      Format.eprintf ">> Binding occurrence of mutable variable marked as not \
          being from the current compilation unit: %a"
        Mutable_variable.print mut_var
    | Binding_occurrence_of_variable_already_bound var ->
      Format.eprintf ">> Binding occurrence of variable that was already \
            bound: %a"
        Variable.print var
    | Binding_occurrence_of_mutable_variable_already_bound mut_var ->
      Format.eprintf ">> Binding occurrence of mutable variable that was \
            already bound: %a"
        Mutable_variable.print mut_var
    | Binding_occurrence_of_symbol_already_bound sym ->
      Format.eprintf ">> Binding occurrence of symbol that was already \
            bound: %a"
        Symbol.print sym
    | Unbound_variable var ->
      Format.eprintf ">> Unbound variable: %a" Variable.print var
    | Unbound_mutable_variable mut_var ->
      Format.eprintf ">> Unbound mutable variable: %a"
        Mutable_variable.print mut_var
    | Unbound_symbol sym ->
      Format.eprintf ">> Unbound symbol: %a %s"
        Symbol.print sym
        (Printexc.raw_backtrace_to_string (Printexc.get_callstack 100))
    | Bad_free_vars_in_function_body
        (vars, set_of_closures, fun_var) ->
      Format.eprintf ">> Variable(s) (%a) in the body of a function \
          declaration (closure_id = %a) that is neither the [my_closure] \
          variable nor one of the function's parameters.  Set of closures: %a"
        Variable.Set.print vars
        Closure_id.print fun_var
        Flambda.Set_of_closures.print set_of_closures
    | Function_decls_have_overlapping_parameters vars ->
      Format.eprintf ">> Function declarations whose parameters overlap: \
          %a"
        Variable.Set.print vars
    | Projection_must_be_a_free_var var ->
      Format.eprintf ">> Projection %a in [free_vars] from a variable that is \
          not a (inner) free variable of the set of closures"
        Projection.print var
    | Projection_must_be_a_parameter var ->
      Format.eprintf ">> Projection %a in [params] from a variable \
          that is not a parameter of the same function"
        Projection.print var
    | Sequential_logical_operator_primitives_must_be_expanded prim ->
      Format.eprintf ">> Sequential logical operator primitives must be \
          expanded (see closure_conversion.ml): %a"
        Printlambda.primitive prim
    | Set_of_closures_id_is_bound_multiple_times set_of_closures_id ->
      Format.eprintf ">> Set of closures ID is bound multiple times: %a"
        Set_of_closures_id.print set_of_closures_id
    | Declared_closure_from_another_unit compilation_unit ->
      Format.eprintf ">> Closure declared as being from another compilation \
          unit: %a"
        Compilation_unit.print compilation_unit
    | Unbound_closure_ids closure_ids ->
      Format.eprintf ">> Unbound closure ID(s) from the current compilation \
          unit: %a"
        Closure_id.Set.print closure_ids
    | Unbound_vars_within_closures vars_within_closures ->
      Format.eprintf ">> Unbound variable(s) within closure(s) from the \
          current compilation_unit: %a"
        Var_within_closure.Set.print vars_within_closures
    | Continuation_not_caught (static_exn, s) ->
      Format.eprintf ">> Uncaught continuation variable %a: %s"
        Continuation.print static_exn s
    | Access_to_global_module_identifier prim ->
      (* CR-someday mshinwell: backend-specific checks should move to another
        module, in the asmcomp/ directory. *)
      Format.eprintf ">> Forbidden access to a global module identifier (not \
          allowed in Flambda that will be exported to a .cmx file): %a"
        Printlambda.primitive prim
    | Pidentity_should_not_occur ->
      Format.eprintf ">> The Pidentity primitive should never occur in an \
        Flambda expression (see closure_conversion.ml)"
    | Pdirapply_should_be_expanded ->
      Format.eprintf ">> The Pdirapply primitive should never occur in an \
        Flambda expression (see simplif.ml); use Apply instead"
    | Prevapply_should_be_expanded ->
      Format.eprintf ">> The Prevapply primitive should never occur in an \
        Flambda expression (see simplif.ml); use Apply instead"
    | Ploc_should_be_expanded ->
      Format.eprintf ">> The Ploc primitive should never occur in an \
        Flambda expression (see translcore.ml); use Apply instead"
    | Malformed_exception_continuation (cont, str) ->
      Format.eprintf ">> Malformed exception continuation %a: %s"
        Continuation.print cont
        str
    | Exception_handler_used_as_normal_continuation cont ->
      Format.eprintf ">> Exception handler %a used as normal continuation"
        Continuation.print cont
    | Exception_handler_used_as_return_continuation cont ->
      Format.eprintf ">> Exception handler %a used as return continuation"
        Continuation.print cont
    | Normal_continuation_used_as_exception_handler cont ->
      Format.eprintf ">> Non-exception handler %a used as exception handler"
        Continuation.print cont
    | Empty_switch scrutinee ->
      Format.eprintf ">> Empty switch on %a" Variable.print scrutinee
    | exn -> raise exn
  end;
  Format.eprintf "\n@?";
  raise Flambda_invariants_failed
end
