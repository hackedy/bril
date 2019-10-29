open Core
open Cfg
open Analysis

module Expr = struct
  type t = Bril.value_expr [@@deriving sexp, compare]
end

module ExprMap = Map.Make(Expr)
type expr_typs = Bril.typ ExprMap.t

let merge x y =
  let combine ~key:_ x y =
    if x = y then x else failwith "multiple types?"
  in
  Map.merge_skewed ~combine x y 

let merge_list =
  List.fold ~f:merge ~init:ExprMap.empty

let exprs instr : expr_typs =
  match instr with
  | Cfg.ValueInstr { op = Id _; _ } ->
     ExprMap.empty
  | Cfg.ValueInstr { op; typ; _ } ->
     ExprMap.singleton op typ
  | _ -> 
     ExprMap.empty

let aggregate_expressions_block (b, _) =
  merge_list @@ List.map ~f:exprs b.body

let aggregate_expression_typs graph =
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

  module Entry : Analysis.Analysis =
    MakeBlockLocal
      (struct
        let attr_name = "entry"
        let analyze (_, block_attrs) =
          if Bitv.all_zeros @@ Attrs.get block_attrs "entry"
          then zeros
          else ones
      end)

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

  let avail_out (_, block_attrs) avail_in =
    Bitv.bw_or
      (Bitv.bw_and
         (Cfg.Attrs.get block_attrs "transparent")
         avail_in)
      (Cfg.Attrs.get block_attrs "computes")

  module AvailabilityIn =
    MakeDataflow
      (struct
        let attr_name = "availability_in"
        let direction = Graph.Fixpoint.Forward
        let init _ =
          EXPRS.build ~f:(fun _ -> false)
        let analyze (src, _, _) src_avail_in =
          avail_out src src_avail_in
      end)

  module AvailabilityOut =
    MakeBlockLocal
      (struct
        let attr_name = "availability_out"
        let analyze block =
          avail_out block (Cfg.Attrs.get (snd block) "availability_in")
      end)

  let ant_in (_, attrs) ant_out =
    Bitv.bw_or
      (Bitv.bw_and
         (Cfg.Attrs.get attrs "transparent")
         ant_out)
      (Cfg.Attrs.get attrs "locally_anticipates")

  module AnticipatabilityOut =
    MakeDataflow
      (struct
        let attr_name = "anticipatability_out"
        let direction = Graph.Fixpoint.Backward
        let init (_, b_attrs) =
          if Bitv.all_zeros @@ Cfg.Attrs.get b_attrs "exit"
          then EXPRS.build ~f:(fun _ -> true)
          else EXPRS.build ~f:(fun _ -> false)
        let analyze (_, _, dst) dst_ant_out =
          ant_in dst dst_ant_out
      end)

  module AnticipatabilityIn =
    MakeBlockLocal
      (struct
        let attr_name = "anticipatability_in"
        let analyze block =
          ant_in block (Cfg.Attrs.get (snd block) "anticipatability_out")
      end)

  module Earliest =
    MakeEdgeLocal
      (struct
        let attr_name = "earliest"
        let analyze ((_, src_attrs), _, (_, dst_attrs)) =
          let ant_in_dst = Cfg.Attrs.get dst_attrs "anticipatability_in" in
          let avail_out_src = Cfg.Attrs.get src_attrs "availability_out" in
          let entry_cond = Bitv.bw_and ant_in_dst (Bitv.bw_not avail_out_src) in
          if Bitv.all_zeros @@ Cfg.Attrs.get src_attrs "entry"
          then Bitv.bw_and
                 entry_cond
                 (Bitv.bw_or
                    (Bitv.bw_not (Cfg.Attrs.get src_attrs "transparent"))
                    (Bitv.bw_not (Cfg.Attrs.get src_attrs "anticipatability_out")))
          else entry_cond
      end)
          
  module Later =
    MakeDataflow
      (struct
        let attr_name = "later"
        let direction = Graph.Fixpoint.Forward
        let init (_, b_attrs) = 
          let v = EXPRS.build ~f:(fun _ -> false)
          in
          Hashtbl.set ~key:"later_in" ~data:v b_attrs;
          v
        let analyze ((_, src_attrs), edge_attrs, (_, _)) src_later_in =
          let later_src_dst =
            Bitv.bw_or
              (Bitv.bw_and src_later_in
                 (Bitv.bw_not (Cfg.Attrs.get src_attrs "locally_anticipates")))
              (Cfg.Attrs.get edge_attrs "earliest")
          in
          Hashtbl.set ~key:"later_in" ~data:src_later_in src_attrs; (* hack *)
          Hashtbl.set ~key:"later" ~data:later_src_dst edge_attrs; (* hack *)
          later_src_dst
      end)

  module Insert =
    MakeEdgeLocal
      (struct
        let attr_name = "insert"
        let analyze (_, edge_attrs, (_, dst_attrs)) =
          Bitv.bw_and
            (Cfg.Attrs.get edge_attrs "later")
            (Bitv.bw_not (Cfg.Attrs.get dst_attrs "later_in"))
      end)

  module Delete =
    MakeBlockLocal
      (struct
        let attr_name = "delete"
        let analyze (_, block_attrs) =
          if Bitv.all_zeros @@ Cfg.Attrs.get block_attrs "entry"
          then Bitv.bw_and
                 (Cfg.Attrs.get block_attrs "locally_anticipates")
                 (Bitv.bw_not (Cfg.Attrs.get block_attrs "later_in"))
          else zeros
      end)
end
