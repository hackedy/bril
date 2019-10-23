open Core
open Cfg
open Analysis

module Expr = struct
  type t = Bril.value_expr [@@deriving sexp, compare]
end

module Var = struct
  type t = Ident.var [@@deriving sexp, compare]
end

module VarSet = Set.Make(Var)
module ExprMap = Map.Make(Expr)
type expr_locs = VarSet.t ExprMap.t

let merge x y =
  let combine ~key:_ = VarSet.union in
  Map.merge_skewed ~combine x y 

let merge_list =
  List.fold ~f:merge ~init:ExprMap.empty

let exprs instr : expr_locs =
  match instr with
  | Cfg.ValueInstr { op; dest; _ } ->
     ExprMap.singleton op @@ VarSet.singleton dest
  | _ -> 
     ExprMap.empty

let aggregate_expressions_block (b, _) =
  merge_list @@ List.map ~f:exprs b.body

let aggregate_expression_locs graph =
  let do_vtx block exprs =
    merge exprs (aggregate_expressions_block block)
  in
  CFG.fold_vertex do_vtx graph ExprMap.empty

let assigns_to var instr =
  match instr with
  | ConstInstr {dest; _}
  | ValueInstr {dest; _} ->
     dest = var
  | _ -> false

let instr_transparent expression instr =
  let doesnt_assign_to var =
    not (assigns_to var instr)
  in
  List.for_all ~f:doesnt_assign_to @@ Bril.args expression

let instrs_transparent expression instrs =
  List.for_all ~f:(instr_transparent expression) instrs

let expr_transparent expression block =
  instrs_transparent expression block.body

let instr_computes expression instr =
  match instr with
  | Cfg.ValueInstr { op; _ } ->
     op = expression
  | _ -> false

let expr_computes expression block =
  let rec computes' instrs =
    match instrs with
    | [] -> false
    | instr :: instrs ->
       if instr_computes expression instr
       then instrs_transparent expression instrs
       else computes' instrs
  in
  computes' block.body

module type Exprs = sig
  val expressions : Bril.value_expr list
  val build : f:(Bril.value_expr -> bool) -> Bitv.t
end

module Analyze (EXPRS: Exprs) = struct

  let ones = EXPRS.build ~f:(fun _ -> true)
  let zeros = EXPRS.build ~f:(fun _ -> false)

  module Entry : Analysis.Analysis = struct
    let run graph =
      let mark v =
        let (_, block_attrs) = v in
        let data =
          if List.length (CFG.pred graph v) > 0
          then zeros
          else ones
        in
        Hashtbl.set ~key:"entry" block_attrs ~data
      in
      CFG.iter_vertex mark graph;
      graph
  end

  module Exit : Analysis.Analysis = struct
    let run graph =
      let mark v =
        let (_, block_attrs) = v in
        let data =
          if List.length (CFG.succ graph v) > 0
          then zeros
          else ones
        in
        Hashtbl.set ~key:"exit" block_attrs ~data
      in
      CFG.iter_vertex mark graph;
      graph
  end

  module Transparent =
    MakeBlockLocal
      (struct
        let attr_name = "transparent"
        let analyze (block, _) =
          EXPRS.build ~f:(fun expr -> expr_transparent expr block)
      end)

  module Computes =
    MakeBlockLocal
      (struct 
        let attr_name = "computes"
        let analyze (block, _) =
          EXPRS.build ~f:(fun expr -> expr_computes expr block)
      end)

  module LocallyAnticipates =
    MakeBlockLocal
      (struct 
        let attr_name = "locally_anticipates"
        let analyze (block, _) =
          let block' = {block with body = List.rev block.body} in
          EXPRS.build ~f:(fun expr -> expr_computes expr block')
      end)

  module Availability =
    MakeDataflow
      (struct
        let attr_name = "availability"
        let direction = Graph.Fixpoint.Forward
        let init (_, b_attrs) =
          if Bitv.all_zeros @@ Cfg.Attrs.get b_attrs "entry"
          then EXPRS.build ~f:(fun _ -> true)
          else EXPRS.build ~f:(fun _ -> false)
        let analyze ((_, src_attrs), _, _) src_avail_in =
          Bitv.bw_or
            (Bitv.bw_and
               (Cfg.Attrs.get src_attrs "transparent")
               src_avail_in)
            (Cfg.Attrs.get src_attrs "computes")
      end)

  module Anticipatability =
    MakeDataflow
      (struct
        let attr_name = "anticipatability"
        let direction = Graph.Fixpoint.Backward
        let init (_, b_attrs) =
          if Bitv.all_zeros @@ Cfg.Attrs.get b_attrs "exit"
          then EXPRS.build ~f:(fun _ -> true)
          else EXPRS.build ~f:(fun _ -> false)
        let analyze (_, _, (_, dst_attrs)) dst_ant_out =
          let transp = Cfg.Attrs.get dst_attrs "transparent" in
          Bitv.bw_or
            (Bitv.bw_and
               transp
               dst_ant_out)
            (Cfg.Attrs.get dst_attrs "locally_anticipates")
      end)

  module Earliest =
    MakeEdgeLocal
      (struct
        let attr_name = "earliest"
        let analyze ((_, src_attrs), _, (_, dst_attrs)) =
          let ant_in_dst = Cfg.Attrs.get dst_attrs "anticipatability" in
          let avail_out_src = Cfg.Attrs.get src_attrs "availability" in
          let entry_cond = Bitv.bw_and ant_in_dst (Bitv.bw_not avail_out_src) in
          Bitv.bw_and entry_cond
            (Bitv.bw_or
               (Bitv.bw_not (Cfg.Attrs.get src_attrs "transparent"))
               (* this should be ant_out not ant_in *)
               (Bitv.bw_not (Cfg.Attrs.get src_attrs "anticipatability")))
      end)
          
  module Later =
    Graph.Fixpoint.Make(CFG)
      (struct
        type vertex = CFG.E.vertex
        type edge = CFG.E.t
        type g = CFG.t
        type data = Bitv.t
        let direction = Graph.Fixpoint.Forward
        let equal x y = Bitv.all_zeros (Bitv.bw_xor x y) (* hack *)
        let join = Bitv.bw_and
        let analyze ((_, src_attrs), edge_attrs, (_, _)) src_later_in =
          Bitv.bw_or
            (Bitv.bw_and src_later_in
               (Bitv.bw_not (Cfg.Attrs.get src_attrs "locally_anticipates")))
            (Cfg.Attrs.get edge_attrs "earliest")
      end)
end
