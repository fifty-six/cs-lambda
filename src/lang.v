From stdpp Require Export binders strings.
From stdpp Require Import fin_maps gmap.
From iris.algebra Require Export ofe.
From iris.program_logic Require Export language ectx_language ectxi_language.
From iris.heap_lang Require Export locations.
From iris.prelude Require Import options.


(** cs_lambda.  

A fairly simple language used for common Iris examples.

Noteworthy design choices:

- This is a right-to-left evaluated language, like CakeML and OCaml.  The reason
  for this is that it makes curried functions usable: Given a WP for [f a b], we
  know that any effects [f] might have to not matter until after *both* [a] and
  [b] are evaluated.  With left-to-right evaluation, that triple is basically
  useless unless the user let-expands [b].

- Even after deallocating a location, the heap remembers that these locations
  were previously allocated and makes sure they do not get reused. This is
  necessary to ensure soundness of the [meta] feature provided by [gen_heap].
  Also, unlike in languages like C, allocated and deallocated "blocks" do not
  have to match up: you can allocate a large array of locations and then
  deallocate a hole out of it in the middle.
*)

Delimit Scope expr_scope with E.
Delimit Scope val_scope with V.

Module cs_lambda.

(** Expressions and vals. *)
Definition proph_id := positive.

(** We have a notion of "poison" as a variant of unit that may not be compared
with anything. This is useful for erasure proofs: if we erased things to unit,
[<erased> == unit] would evaluate to true after erasure, changing program
behavior. So we erase to the poison value instead, making sure that no legal
comparisons could be affected. *)

Inductive base_lit : Set :=
  | LitInt (n : Z) 
  | LitBool (b : bool) 
  | LitUnit.
Inductive un_op : Set :=
  | NegOp | MinusUnOp.
Inductive bin_op : Set :=
  | PlusOp
  | AndOp
  | EqOp.

Inductive expr :=
  (* Values *)
  | Val (v : val)
  (* Base lambda calculus *)
  | Var (x : string)
  | Rec (f x : binder) (e : expr)
  | App (e1 e2 : expr)
  (* Base types and their operations *)
  | UnOp (op : un_op) (e : expr)
  | BinOp (op : bin_op) (e1 e2 : expr)
  | If (e0 e1 e2 : expr)
  (* Products *)
  (* a ref pair is our equivalent of a ref struct, as a struct is just a product type with named fields, otherwise it's just a struct? *)
  | Pair (ref: bool) (e1 e2 : expr)
  | Fst (e : expr)
  | Snd (e : expr)
  | Ref (e: expr)
  | Class (e1 e2 : expr)
with val :=
  | LitV (l : base_lit)
  | RecV (f x : binder) (e : expr)
  | PairV (ref : bool) (v1 v2 : val).

Bind Scope expr_scope with expr.
Bind Scope val_scope with val.

Inductive type : Type :=
  | TInt   : type
  | TBool  : type
  | TPair  : bool -> type -> type -> type
  | TClass : type -> type -> type
  | TRef   : type -> type
  | TArrow : type -> type -> type
  | TUnit  : type.

(* 
field_valid property holds if type can be used as a field in 
  - struct/class (when bool is false) 
  - ref struct (when bool is true) 
*)
Inductive field_valid : type -> bool -> Prop :=
  | FVInt   : forall (b : bool), field_valid TInt b
  | FVUnit  : forall (b : bool), field_valid TUnit b
  (* functions aren't really special *)
  | FVArrow ??1 ??2: forall (b : bool), field_valid (TArrow ??1 ??2) b
  (* non-ref pairs are fine for any type of pair, just check for nested stuff *)
  | FVPair ??1 ??2 : forall (b : bool),
      field_valid ??1 false -> field_valid ??2 false -> field_valid (TPair false ??1 ??2) b
  (* provided our args are fine for a ref pair, we can have a ref pair as a field *)
  | FVPairR ??1 ??2:
      field_valid ??1 true -> field_valid ??2 true -> field_valid (TPair true ??1 ??2) true.

Reserved Notation "?? ??? e : ??" (at level 74, e, ?? at next level).

Inductive has_type (??: gmap binder type) : expr -> type -> Prop :=
  | IntT n : 
      ?? ??? (Val (LitV (LitInt n))) : TInt
  | BoolT b :
      ?? ??? (Val (LitV (LitBool b))) : TBool
  | UnitT :
      ?? ??? (Val (LitV (LitUnit))) : TUnit
  | RecVT f x e ??1 ??2 : 
      (* if giving x the type ??1 in the context resolves the expression, then the function is valid *)
      (<[ x := ??1 ]> ??) ??? e : ??2 ->
      ?? ??? (Val (RecV f x e)) : TArrow ??1 ??2
  | PairVT ref v1 v2 ??1 ??2 : 
      ?? ??? Val v1 : ??1 -> 
      ?? ??? Val v2 : ??2 ->
      field_valid ??1 ref -> 
      field_valid ??2 ref ->
      ?? ??? (Val (PairV ref v1 v2)) : TPair ref ??1 ??2
  | VarT x ??1 :
      (* x is type string but context wants binder *)
      (lookup (BNamed x) ??) = Some ??1 ->
      ?? ??? (Var x) : ??1
  | RecT f x e ??1 ??2 : 
      (* if giving x the type ??1 in the context resolves the expression, then the function is valid *)
      (<[ x := ??1 ]> ??) ??? e : ??2 ->
      ?? ??? Rec f x e : TArrow ??1 ??2
  | AppT e1 e2 ??1 ??2 :
      ?? ??? e1 : (TArrow ??1 ??2) ->
      ?? ??? e2 : ??1 -> 
      ?? ??? (App e1 e2) : ??2
  | NegT e1 :
      ?? ??? e1 : TBool ->
      ?? ??? (UnOp NegOp e1) : TBool
  | MinusT e1 :
      ?? ??? e1 : TInt ->
      ?? ??? (UnOp MinusUnOp e1) : TInt
  | PlusT e1 e2 :
      ?? ??? e1 : TInt ->
      ?? ??? e2 : TInt -> 
      ?? ??? (BinOp PlusOp e1 e2) : TInt
  | AndT e1 e2 :
      ?? ??? e1 : TBool ->
      ?? ??? e2 : TBool -> 
      ?? ??? (BinOp AndOp e1 e2) : TBool
  | EqT e1 e2 :
      ?? ??? e1 : TBool ->
      ?? ??? e2 : TBool -> 
      ?? ??? (BinOp EqOp e1 e2) : TBool
  | IfT e1 e2 e3 ??1 : 
      ?? ??? e1 : TBool ->
      ?? ??? e2 : ??1 -> 
      ?? ??? e3 : ??1 -> 
      ?? ??? (If e1 e2 e3) : ??1    
  | PairT ref e1 e2 ??1 ??2 : 
      ?? ??? e1 : ??1 -> 
      ?? ??? e2 : ??2 ->
      field_valid ??1 ref -> 
      field_valid ??2 ref ->
      ?? ??? (Pair ref e1 e2) : TPair ref ??1 ??2
  | FstT e1 ref ??1 ??2 :
      ?? ??? e1 : TPair ref ??1 ??2 ->
      ?? ??? (Fst e1) : ??1  
  | SndT e1 ref ??1 ??2 :
      ?? ??? e1 : TPair ref ??1 ??2 ->
      ?? ??? (Snd e1) : ??2
  | RefT x ??1 :
      ?? ??? (Var x) : ??1 -> 
      ?? ??? (Ref (Var x)) : TRef ??1
  | ClassT e1 e2 ??1 ??2 : 
      ?? ??? e1 : ??1 -> 
      ?? ??? e2 : ??2 -> 
      field_valid ??1 false -> 
      field_valid ??2 false -> 
      ?? ??? (Class e1 e2) : TClass ??1 ??2
(* e has type tau *)
where "?? ??? e : ??" := (has_type ?? e ??).

(*


(** An observation associates a prophecy variable (identifier) to a pair of
values. The first value is the one that was returned by the (atomic) operation
during which the prophecy resolution happened (typically, a boolean when the
wrapped operation is a CmpXchg). The second value is the one that the prophecy
variable was actually resolved to. *)
Definition observation : Set := proph_id * (val * val).

Notation of_val := Val (only parsing).

Definition to_val (e : expr) : option val :=
  match e with
  | Val v => Some v
  | _ => None
  end.

(** We assume the following encoding of values to 64-bit words: The least 3
significant bits of every word are a "tag", and we have 61 bits of payload,
which is enough if all pointers are 8-byte-aligned (common on 64bit
architectures). The tags have the following meaning:

0: Payload is the data for a LitV (LitInt _).
1: Payload is the data for a InjLV (LitV (LitInt _)).
2: Payload is the data for a InjRV (LitV (LitInt _)).
3: Payload is the data for a LitV (LitLoc _).
4: Payload is the data for a InjLV (LitV (LitLoc _)).
4: Payload is the data for a InjRV (LitV (LitLoc _)).
6: Payload is one of the following finitely many values, which 61 bits are more
   than enough to encode:
   LitV LitUnit, InjLV (LitV LitUnit), InjRV (LitV LitUnit),
   LitV LitPoison, InjLV (LitV LitPoison), InjRV (LitV LitPoison),
   LitV (LitBool _), InjLV (LitV (LitBool _)), InjRV (LitV (LitBool _)).
7: Value is boxed, i.e., payload is a pointer to some read-only memory area on
   the heap which stores whether this is a RecV, PairV, InjLV or InjRV and the
   relevant data for those cases. However, the boxed representation is never
   used if any of the above representations could be used.

Ignoring (as usual) the fact that we have to fit the infinite Z/loc into 61
bits, this means every value is machine-word-sized and can hence be atomically
read and written.  Also notice that the sets of boxed and unboxed values are
disjoint. *)
Definition lit_is_unboxed (l: base_lit) : Prop :=
  match l with
  (** Disallow comparing (erased) prophecies with (erased) prophecies, by
  considering them boxed. *)
  | LitInt _ | LitBool _  | LitLoc _ | LitUnit => True
  end.

Definition val_is_unboxed (v : val) : Prop :=
  match v with
  | LitV l         => lit_is_unboxed l
  | _              => False
  end.

Definition expr_ref (e : expr) : Prop :=
  match e with 
  | Ref _  => True
  | _      => False
  end.

Global Instance lit_is_unboxed_dec l : Decision (lit_is_unboxed l).
Proof. 
  destruct l;
  simpl;
  exact (decide _).
Defined.

Global Instance val_is_unboxed_dec v : Decision (val_is_unboxed v).
Proof. 
  destruct v; 
  simpl; 
  exact (decide _). 
Defined.

Global Instance expr_ref_dec v : Decision (expr_is_ref v).
Proof.
  destruct v;
  simpl;
  exact (decide _).
Defined.

(** We just compare the word-sized representation of two values, without looking
into boxed data.  This works out fine if at least one of the to-be-compared
values is unboxed (exploiting the fact that an unboxed and a boxed value can
never be equal because these are disjoint sets). *)
Definition vals_compare_safe (vl v1 : val) : Prop :=
  val_is_unboxed vl ??? val_is_unboxed v1.
Global Arguments vals_compare_safe !_ !_ /.

(** The state: heaps of [option val]s, with [None] representing deallocated locations. *)
Record state : Type := {
  heap: gmap loc (option val);
  used_proph_id: gset proph_id;
}.

(** Equality and other typeclass stuff *)
Lemma to_of_val v : to_val (of_val v) = Some v.
Proof. 
  by destruct v. 
Qed.

Lemma of_to_val e v : to_val e = Some v ??? of_val v = e.
Proof. 
  destruct e=>//=. 
  by intros [= <-]. 
Qed.

Global Instance of_val_inj : Inj (=) (=) of_val.
Proof. 
  intros ??. 
  congruence. 
Qed.

Global Instance base_lit_eq_dec : EqDecision base_lit.
Proof. solve_decision. Defined.
Global Instance un_op_eq_dec : EqDecision un_op.
Proof. solve_decision. Defined.
Global Instance bin_op_eq_dec : EqDecision bin_op.
Proof. solve_decision. Defined.
Global Instance expr_eq_dec : EqDecision expr.
Proof.
  refine (
   fix go (e1 e2 : expr) {struct e1} : Decision (e1 = e2) :=
     match e1, e2 with
     | Val v, Val v'                   => cast_if (decide (v = v'))
     | Var x, Var x'                   => cast_if (decide (x = x'))
     | Rec f x e, Rec f' x' e'         => cast_if_and3 (decide (f = f')) (decide (x = x')) (decide (e = e'))
     | App e1 e2, App e1' e2'          => cast_if_and (decide (e1 = e1')) (decide (e2 = e2'))
     | UnOp o e, UnOp o' e'            => cast_if_and (decide (o = o')) (decide (e = e')) 
     | BinOp o e1 e2, BinOp o' e1' e2' => cast_if_and3 (decide (o = o')) (decide (e1 = e1')) (decide (e2 = e2'))
     | If e0 e1 e2, If e0' e1' e2'     => cast_if_and3 (decide (e0 = e0')) (decide (e1 = e1')) (decide (e2 = e2'))
     | Pair r e1 e2, Pair r' e1' e2'   => cast_if_and3 (decide (r = r')) (decide (e1 = e1')) (decide (e2 = e2'))
     | Fst e, Fst e'                   => cast_if (decide (e = e'))
     | Snd e, Snd e'                   => cast_if (decide (e = e'))
     | AllocN e1 e2, AllocN e1' e2'    => cast_if_and (decide (e1 = e1')) (decide (e2 = e2'))
     | Free e, Free e'                 => cast_if (decide (e = e'))
     | Load e, Load e'                 => cast_if (decide (e = e'))
     | Store e1 e2, Store e1' e2'      => cast_if_and (decide (e1 = e1')) (decide (e2 = e2'))
     | Ref e, Ref e'                   => cast_if (decide (e = e'))
     | _, _                            => right _
     end
   with gov (v1 v2 : val) {struct v1} : Decision (v1 = v2) :=
     match v1, v2 with
     | LitV l, LitV l'                 => cast_if (decide (l = l'))
     | RecV f x e, RecV f' x' e'  => cast_if_and3 (decide (f = f')) (decide (x = x')) (decide (e = e'))
     | PairV r e1 e2, PairV r' e1' e2' => cast_if_and3 (decide (r = r')) (decide (e1 = e1')) (decide (e2 = e2'))
     | _, _                            => right _
     end
   for go); try (clear go gov; abstract intuition congruence).
Defined.
Global Instance val_eq_dec : EqDecision val.
Proof. solve_decision. Defined.

Global Instance state_inhabited : Inhabited state :=
  populate {| heap := inhabitant; used_proph_id := inhabitant |}.
Global Instance val_inhabited : Inhabited val := populate (LitV LitUnit).
Global Instance expr_inhabited : Inhabited expr := populate (Val inhabitant).

(** Evaluation contexts *)
(** Note that [ResolveLCtx] is not by itself an evaluation context item: we do
not reduce directly under Resolve's first argument. We only reduce things nested
further down. Once no nested contexts exist any more, the expression must take
exactly one more step to a value, and Resolve then (atomically) also uses that
value for prophecy resolution.  *)
Inductive ectx_item :=
  | AppLCtx (v2 : val)
  | AppRCtx (e1 : expr)
  | UnOpCtx (op : un_op)
  | BinOpLCtx (op : bin_op) (v2 : val)
  | BinOpRCtx (op : bin_op) (e1 : expr)
  | IfCtx (e1 e2 : expr)
  | PairLCtx (ref : bool) (v2 : val)
  | PairRCtx (ref : bool) (e1 : expr)
  | FstCtx
  | SndCtx
  | AllocNLCtx (v2 : val)
  | AllocNRCtx (e1 : expr)
  | FreeCtx
  | LoadCtx
  | StoreLCtx (v2 : val)
  | StoreRCtx (e1 : expr).

(** Contextual closure will only reduce [e] in [Resolve e (Val _) (Val _)] if
the local context of [e] is non-empty. As a consequence, the first argument of
[Resolve] is not completely evaluated (down to a value) by contextual closure:
no head steps (i.e., surface reductions) are taken. This means that contextual
closure will reduce [Resolve (CmpXchg #l #n (#n + #1)) #p #v] into [Resolve
(CmpXchg #l #n #(n+1)) #p #v], but it cannot context-step any further. *)

Definition fill_item (Ki : ectx_item) (e : expr) : expr :=
  match Ki with
  | AppLCtx v2      => App e (of_val v2)
  | AppRCtx e1      => App e1 e
  | UnOpCtx op      => UnOp op e
  | BinOpLCtx op v2 => BinOp op e (Val v2)
  | BinOpRCtx op e1 => BinOp op e1 e
  | IfCtx e1 e2     => If e e1 e2
  | PairLCtx r v2   => Pair r e (Val v2)
  | PairRCtx r e1   => Pair r e1 e
  | FstCtx          => Fst e
  | SndCtx          => Snd e
  | AllocNLCtx v2   => AllocN e (Val v2)
  | AllocNRCtx e1   => AllocN e1 e
  | FreeCtx         => Free e
  | LoadCtx         => Load e
  | StoreLCtx v2    => Store e (Val v2)
  | StoreRCtx e1    => Store e1 e
  end.

(** Substitution *)
Fixpoint subst (x : string) (v : val) (e : expr)  : expr :=
  match e with
  | Val _          => e
  | Var y          => if decide (x = y) then Val v else Var y
  | Rec f y e      => Rec f y $ if decide (BNamed x ??? f ??? BNamed x ??? y) then subst x v e else e
  | App e1 e2      => App (subst x v e1) (subst x v e2)
  | UnOp op e      => UnOp op (subst x v e)
  | BinOp op e1 e2 => BinOp op (subst x v e1) (subst x v e2)
  | If e0 e1 e2    => If (subst x v e0) (subst x v e1) (subst x v e2)
  | Pair r e1 e2   => Pair r (subst x v e1) (subst x v e2)
  | Fst e          => Fst (subst x v e)
  | Snd e          => Snd (subst x v e)
  | AllocN e1 e2   => AllocN (subst x v e1) (subst x v e2)
  | Free e         => Free (subst x v e)
  | Load e         => Load (subst x v e)
  | Store e1 e2    => Store (subst x v e1) (subst x v e2)
  | Ref e          => Ref (subst x v e)
  end.

Definition subst' (mx : binder) (v : val) : expr ??? expr :=
  match mx with BNamed x => subst x v | BAnon => id end.

(** The stepping relation *)
Definition un_op_eval (op : un_op) (v : val) : option val :=
  match op, v with
  | NegOp, LitV (LitBool b)    => Some $ LitV $ LitBool (negb b)
  | NegOp, LitV (LitInt n)     => Some $ LitV $ LitInt (Z.lnot n)
  | MinusUnOp, LitV (LitInt n) => Some $ LitV $ LitInt (- n)
  | _, _ => None
  end.

Definition bin_op_eval_int (op : bin_op) (n1 n2 : Z) : option base_lit :=
  match op with
  | PlusOp   => Some $ LitInt  (n1 + n2)
  | AndOp    => Some $ LitInt  (Z.land n1 n2)
  | EqOp     => Some $ LitBool (bool_decide (n1 = n2))
  | OffsetOp => None (* Pointer arithmetic *)
  end%Z.

Definition bin_op_eval_bool (op : bin_op) (b1 b2 : bool) : option base_lit :=
  match op with
  | PlusOp              => None (* Arithmetic *)
  | AndOp               => Some (LitBool (b1 && b2))
  | EqOp                => Some (LitBool (bool_decide (b1 = b2)))
  | OffsetOp            => None (* Pointer arithmetic *)
  end.

Definition bin_op_eval_loc (op : bin_op) (l1 : loc) (v2 : base_lit) : option base_lit :=
  match op, v2 with
  | OffsetOp, LitInt off => Some $ LitLoc (l1 +??? off)
  | _, _ => None
  end.

Definition bin_op_eval (op : bin_op) (v1 v2 : val) : option val :=
  if decide (op = EqOp) then
    (* Crucially, this compares the same way as [CmpXchg]! *)
    if decide (vals_compare_safe v1 v2) then
      Some $ LitV $ LitBool $ bool_decide (v1 = v2)
    else
      None
  else
    match v1, v2 with
    | LitV (LitInt n1), LitV (LitInt n2)   => LitV <$> bin_op_eval_int op n1 n2
    | LitV (LitBool b1), LitV (LitBool b2) => LitV <$> bin_op_eval_bool op b1 b2
    | LitV (LitLoc l1), LitV v2            => LitV <$> bin_op_eval_loc op l1 v2
    | _, _ => None
    end.

Definition state_upd_heap (f: gmap loc (option val) ??? gmap loc (option val)) (??: state) : state :=
  {| heap := f ??.(heap); used_proph_id := ??.(used_proph_id) |}.
Global Arguments state_upd_heap _ !_ /.

Definition state_upd_used_proph_id (f: gset proph_id ??? gset proph_id) (??: state) : state :=
  {| heap := ??.(heap); used_proph_id := f ??.(used_proph_id) |}.
Global Arguments state_upd_used_proph_id _ !_ /.

Fixpoint heap_array (l : loc) (vs : list val) : gmap loc (option val) :=
  match vs with
  | [] => ???
  | v :: vs' => {[l := Some v]} ??? heap_array (l +??? 1) vs'
  end.

Lemma heap_array_singleton l v : heap_array l [v] = {[l := Some v]}.
Proof. by rewrite /heap_array right_id. Qed.

Lemma heap_array_lookup l vs ow k :
  heap_array l vs !! k = Some ow ???
  ??? j w, (0 ??? j)%Z ??? k = l +??? j ??? ow = Some w ??? vs !! (Z.to_nat j) = Some w.
Proof.
  revert k l; induction vs as [|v' vs IH]=> l' l /=.
  { rewrite lookup_empty. naive_solver lia. }
  rewrite -insert_union_singleton_l lookup_insert_Some IH. split.
  - intros [[-> ?] | (Hl & j & w & ? & -> & -> & ?)].
    { eexists 0, _. rewrite loc_add_0. naive_solver lia. }
    eexists (1 + j)%Z, _. rewrite loc_add_assoc !Z.add_1_l Z2Nat.inj_succ; auto with lia.
  - intros (j & w & ? & -> & -> & Hil). destruct (decide (j = 0)); simplify_eq/=.
    { rewrite loc_add_0; eauto. }
    right. split.
    { rewrite -{1}(loc_add_0 l). intros ?%(inj (loc_add _)); lia. }
    assert (Z.to_nat j = S (Z.to_nat (j - 1))) as Hj.
    { rewrite -Z2Nat.inj_succ; last lia. f_equal; lia. }
    rewrite Hj /= in Hil.
    eexists (j - 1)%Z, _. rewrite loc_add_assoc Z.add_sub_assoc Z.add_simpl_l.
    auto with lia.
Qed.

Lemma heap_array_map_disjoint (h : gmap loc (option val)) (l : loc) (vs : list val) :
  (??? i, (0 ??? i)%Z ??? (i < length vs)%Z ??? h !! (l +??? i) = None) ???
  (heap_array l vs) ##??? h.
Proof.
  intros Hdisj. apply map_disjoint_spec=> l' v1 v2.
  intros (j&w&?&->&?&Hj%lookup_lt_Some%inj_lt)%heap_array_lookup.
  move: Hj. rewrite Z2Nat.id // => ?. by rewrite Hdisj.
Qed.

(* [h] is added on the right here to make [state_init_heap_singleton] true. *)
Definition state_init_heap (l : loc) (n : Z) (v : val) (?? : state) : state :=
  state_upd_heap (?? h, heap_array l (replicate (Z.to_nat n) v) ??? h) ??.

Lemma state_init_heap_singleton l v ?? :
  state_init_heap l 1 v ?? = state_upd_heap <[l:=Some v]> ??.
Proof.
  destruct ?? as [h p]. rewrite /state_init_heap /=. f_equiv.
  rewrite right_id insert_union_singleton_l. done.
Qed.

Inductive head_step : expr ??? state ??? list observation ??? expr ??? state ??? list expr ??? Prop :=
  | RecS f x e ?? :
     head_step (Rec f x e) ?? [] (Val $ RecV f x e) ?? []
  | PairS r v1 v2 ?? :
     head_step (Pair r (Val v1) (Val v2)) ?? [] (Val $ PairV r v1 v2) ?? []
  | BetaS f x e1 v2 e' ?? :
     e' = subst' x v2 (subst' f (RecV f x e1) e1) ???
     head_step (App (Val $ RecV f x e1) (Val v2)) ?? [] e' ?? []
  | UnOpS op v v' ?? :
     un_op_eval op v = Some v' ???
     head_step (UnOp op (Val v)) ?? [] (Val v') ?? []
  | BinOpS op v1 v2 v' ?? :
     bin_op_eval op v1 v2 = Some v' ???
     head_step (BinOp op (Val v1) (Val v2)) ?? [] (Val v') ?? []
  | IfTrueS e1 e2 ?? :
     head_step (If (Val $ LitV $ LitBool true) e1 e2) ?? [] e1 ?? []
  | IfFalseS e1 e2 ?? :
     head_step (If (Val $ LitV $ LitBool false) e1 e2) ?? [] e2 ?? []
  | FstS r v1 v2 ?? :
     head_step (Fst (Val $ PairV r v1 v2)) ?? [] (Val v1) ?? []
  | SndS r v1 v2 ?? :
     head_step (Snd (Val $ PairV r v1 v2)) ?? [] (Val v2) ?? []
  | AllocNS n v ?? l :
     (0 < n)%Z ???
     (??? i, (0 ??? i)%Z ??? (i < n)%Z ??? ??.(heap) !! (l +??? i) = None) ???
     head_step (AllocN (Val $ LitV $ LitInt n) (Val v)) ??
               []
               (Val $ LitV $ LitLoc l) (state_init_heap l n v ??)
               []
  | FreeS l v ?? :
     ??.(heap) !! l = Some $ Some v ???
     head_step (Free (Val $ LitV $ LitLoc l)) ??
               []
               (Val $ LitV LitUnit) (state_upd_heap <[l:=None]> ??)
               []
  | LoadS l v ?? :
     ??.(heap) !! l = Some $ Some v ???
     head_step (Load (Val $ LitV $ LitLoc l)) ?? [] (of_val v) ?? []
  | StoreS l v w ?? :
     ??.(heap) !! l = Some $ Some v ???
     head_step (Store (Val $ LitV $ LitLoc l) (Val w)) ??
               []
               (Val $ LitV LitUnit) (state_upd_heap <[l:=Some w]> ??)
               [].

(** Basic properties about the language *)
Global Instance fill_item_inj Ki : Inj (=) (=) (fill_item Ki).
Proof. 
  induction Ki; 
  intros ???; 
  simplify_eq/=; 
  auto with f_equal. 
Qed.

Lemma fill_item_val Ki e :
  is_Some (to_val (fill_item Ki e)) ??? is_Some (to_val e).
Proof. 
  intros [v ?].
  induction Ki;
  simplify_option_eq;
  eauto.
Qed.

Lemma val_head_stuck e1 ??1 ?? e2 ??2 efs : head_step e1 ??1 ?? e2 ??2 efs ??? to_val e1 = None.
Proof. 
  destruct 1;
  naive_solver.
Qed.

Lemma head_ctx_step_val Ki e ??1 ?? e2 ??2 efs :
  head_step (fill_item Ki e) ??1 ?? e2 ??2 efs ??? is_Some (to_val e).
Proof. 
  revert ?? e2.
  induction Ki;
  inversion_clear 1;
  simplify_option_eq;
  eauto.
Qed.

Lemma fill_item_no_val_inj Ki1 Ki2 e1 e2 :
  to_val e1 = None ??? to_val e2 = None ???
  fill_item Ki1 e1 = fill_item Ki2 e2 ??? Ki1 = Ki2.
Proof.
  revert Ki1.
  induction Ki2;
  intros Ki1;
  induction Ki1;
  naive_solver eauto with f_equal.
Qed.

Lemma alloc_fresh v n ?? :
  let l := fresh_locs (dom ??.(heap)) in
  (0 < n)%Z ???
  head_step (AllocN ((Val $ LitV $ LitInt $ n)) (Val v)) ?? []
            (Val $ LitV $ LitLoc l) (state_init_heap l n v ??) [].
Proof.
  intros.
  apply AllocNS; first done.
  intros. apply not_elem_of_dom.
  by apply fresh_locs_fresh.
Qed.

Lemma cs_lambda_mixin : EctxiLanguageMixin of_val to_val fill_item head_step.
Proof.
  split; apply _ || eauto using to_of_val, of_to_val, val_head_stuck,
    fill_item_val, fill_item_no_val_inj, head_ctx_step_val.
Qed.
End cs_lambda.

(** Language *)
Canonical Structure heap_ectxi_lang := EctxiLanguage cs_lambda.cs_lambda_mixin.
Canonical Structure heap_ectx_lang  := EctxLanguageOfEctxi heap_ectxi_lang.

(* Prefer cs_lambda names over ectx_language names. *)
Export cs_lambda.

(** The following lemma is not provable using the axioms of [ectxi_language].
The proof requires a case analysis over context items ([destruct i] on the
last line), which in all cases yields a non-value. To prove this lemma for
[ectxi_language] in general, we would require that a term of the form
[fill_item i e] is never a value. *)
Lemma to_val_fill_some K e v : 
  to_val (fill K e) = Some v ??? K = [] ??? e = Val v.
Proof.
  intro H. destruct K as [|Ki K]; first by apply of_to_val in H. exfalso.
  assert (to_val e ??? None) as He.
  { intro A. by rewrite fill_not_val in H. }
  assert (??? w, e = Val w) as [w ->].
  { destruct e; try done; eauto. }
  assert (to_val (fill (Ki :: K) (Val w)) = None).
  { destruct Ki; simpl; apply fill_not_val; done. }
  by simplify_eq.
Qed.

Lemma prim_step_to_val_is_head_step e ??1 ??s w ??2 efs :
  prim_step e ??1 ??s (Val w) ??2 efs ??? head_step e ??1 ??s (Val w) ??2 efs.
Proof.
  intro H. destruct H as [K e1 e2 H1 H2].
  assert (to_val (fill K e2) = Some w) as H3; first by rewrite -H2.
  apply to_val_fill_some in H3 as [-> ->]. subst e. done.
Qed.

(** If [e1] makes a head step to a value under some state [??1] then any head
 step from [e1] under any other state [??1'] must necessarily be to a value. *)
Lemma head_step_to_val e1 ??1 ?? e2 ??2 efs ??1' ??' e2' ??2' efs' :
  head_step e1 ??1 ?? e2 ??2 efs ???
  head_step e1 ??1' ??' e2' ??2' efs' ??? is_Some (to_val e2) ??? is_Some (to_val e2').
Proof. 
  destruct 1;
  inversion 1;
  naive_solver.
Qed.

*)
