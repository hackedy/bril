open Core
open Cfg

let index_of x l =
  let rec go l n =
    match l with
    | [] -> -1
    | y :: l ->
       if y = x
       then n
       else go l (n + 1)
  in
  go l 0

let rec instrs_rewrite ~f instrs =
  match instrs with
  | instr :: instrs ->
     f instr @ instrs_rewrite ~f instrs
  | [] -> []

let block_instr_rewrite ~f (block, meta) =
  let body' = instrs_rewrite ~f block.body in
  { block with body = body' }, meta

let instr_rewrite ~f graph =
  CFG.map_vertex (block_instr_rewrite ~f) graph

let expr_loc exprs expr = 
  "_lcm_tmp" ^ string_of_int (index_of expr exprs)
  |> Ident.var_of_string 

let unify_expression_locations exprs graph =
  let fix_computation = function
    | ValueInstr { op; dest; typ } ->
       if Bril.is_computation op
       then let loc = expr_loc exprs op in
            [ValueInstr { op; dest = loc; typ };
             ValueInstr { op = Id loc; dest = dest; typ }]
       else [ValueInstr { op; dest; typ }]
    | i -> [i]
  in
  instr_rewrite ~f:fix_computation graph

let insert_computations_by exprs graph =
  let _ = exprs in
  CFG.iter_edges_e
    (fun (_, attrs, _) ->
      if Bitv.all_zeros @@ Attrs.get attrs "insert"
      then ()
      else ())
    graph
