open Core

exception BrilJSONParseError of string

let parse_err msg =
  raise @@ BrilJSONParseError msg

let parse_typ : string -> Bril.typ =
  function
  | "int" -> Int
  | "bool" -> Bool
  | _ -> parse_err "not a typ"

let parse_value : Yojson.Basic.t -> Bril.value =
  function
  | `Int i -> Int i
  | `Bool b -> Bool b
  | _ -> parse_err "not a value"

let parse_var =
  function
  | `String s -> Ident.var_of_string s
  | _ -> parse_err "not an ident"

let get_string =
  function
  | `String s -> s
  | _ -> parse_err "expected string"

let parse_value_expr (opcode: string) (args: Yojson.Basic.t list): Bril.value_expr =
  let args = List.map ~f:parse_var args in
  match opcode, args with
  | "add", [arg1; arg2] -> Add (arg1, arg2)
  | "mul", [arg1; arg2] -> Mul (arg1, arg2)
  | "sub", [arg1; arg2] -> Sub (arg1, arg2)
  | "div", [arg1; arg2] -> Div (arg1, arg2)
  | "eq", [arg1; arg2] -> Eq (arg1, arg2)
  | "lt", [arg1; arg2] -> Lt (arg1, arg2)
  | "gt", [arg1; arg2] -> Gt (arg1, arg2)
  | "le", [arg1; arg2] -> Le (arg1, arg2)
  | "ge", [arg1; arg2] -> Ge (arg1, arg2)
  | "not", [arg] -> Not arg
  | "and", [arg1; arg2] -> And (arg1, arg2)
  | "or", [arg1; arg2] -> Or (arg1, arg2)
  | "id", [arg] -> Id arg
  | _ -> parse_err "arity mismatch or unknown opcode for value expr"

let parse_value_op (opcode: string) (args: Yojson.Basic.t list) (dest: string) (typ: string) : Bril.value_op =
  let value_expr = parse_value_expr opcode args in
  let dest = Ident.var_of_string dest in
  let typ = parse_typ typ in
  { op = value_expr;
    dest = dest;
    typ = typ }

let parse_term_op (opcode: string) (args: Yojson.Basic.t list): Bril.term_op =
  let args = List.map ~f:get_string args in
  match opcode, args with
  | "br", [cond; true_lbl; false_lbl] ->
     Br { cond = Ident.var_of_string cond;
          true_lbl = Ident.lbl_of_string true_lbl;
          false_lbl = Ident.lbl_of_string false_lbl }
  | "jmp", [lbl] ->
     Jmp (Ident.lbl_of_string lbl)
  | "ret", [] ->
     Ret
  | _ -> parse_err "arity mismatch or unknown opcode for term op (br, jmp, ret)"

let parse_effect_op (opcode: string) (args: Yojson.Basic.t list): Bril.effect_op =
  match opcode with
  | "print" ->
     Print (List.map ~f:parse_var args)
  | _ ->
     TermOp (parse_term_op opcode args)

let parse_const_op (dest: string) (value: Yojson.Basic.t) (typ: string) : Bril.const_op =
  { dest = Ident.var_of_string dest;
    value = parse_value value;
    typ = parse_typ typ }

let parse_instruction (opcode: string) (props: (string * Yojson.Basic.t) list) : Bril.instruction =
  let args = List.Assoc.find ~equal:(=) props "args" in
  let dest = List.Assoc.find ~equal:(=) props "dest" in
  let typ = List.Assoc.find ~equal:(=) props "type" in
  let value = List.Assoc.find ~equal:(=) props "value" in
  match opcode with
  | "add"
  | "mul"
  | "sub"
  | "div"
  | "eq"
  | "lt"
  | "gt"
  | "le"
  | "ge"
  | "not"
  | "and"
  | "or"
  | "id" ->
     begin match args, dest, typ with
     | Some (`List args), Some (`String dest), Some (`String typ) ->
        ValueInstr (parse_value_op opcode args dest typ)
     | _ -> parse_err "need args, dest, and type fields for value operation"
     end

  | "nop" -> Nop

  | "br"
  | "jmp"
  | "ret"
  | "print" ->
     begin match args with
     | Some (`List args) ->
        EffectInstr (parse_effect_op opcode args)
     | _ -> parse_err "need args for effectful operation (jmp, br, ret, or print)"
     end

  | "const" ->
     begin match value, dest, typ with
     | Some value, Some (`String dest), Some (`String typ) ->
        ConstInstr (parse_const_op dest value typ)
     | _ -> parse_err "need dest, value, and type for const operation"
     end
  | _ -> parse_err "unkown opcode encountered"

let parse_directive (json: Yojson.Basic.t) : Bril.directive =
  match json with
  | `Assoc l ->
     begin match List.Assoc.find ~equal:(=) l "op",
                 List.Assoc.find ~equal:(=) l "label" with
     | Some (`String opcode), _ ->
        Instruction (parse_instruction opcode l)
     | _, Some (`String label) ->
        Label (Ident.lbl_of_string label)
     | _ -> parse_err "expected op/label field to exist and be a string"
     end
  | _ -> parse_err "expected op to have keys"
             

let parse_function (json: Yojson.Basic.t) : Bril.fn =
  match Yojson.Basic.sort json with
  | `Assoc [("instrs", `List instrs); ("name", `String name)] ->
     { name = Ident.fn_of_string name;
       body = List.map ~f:parse_directive instrs }
  | _ -> parse_err "expected function json to have exactly two keys 'instrs', 'name'"

let parse_program (json: Yojson.Basic.t) : Bril.program =
  match json with
  | `Assoc [("functions", `List fns)] ->
     List.map ~f:parse_function fns
  | _ -> parse_err "expected top level json to have a single key 'functions'"

let parse_bril (file: In_channel.t): Bril.program =
  let json = Yojson.Basic.from_channel file in
  parse_program json
