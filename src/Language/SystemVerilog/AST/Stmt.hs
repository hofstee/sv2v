{- sv2v
 - Author: Zachary Snow <zach@zachjs.com>
 - Initial Verilog AST Author: Tom Hawkins <tomahawkins@gmail.com>
 -
 - SystemVerilog procedural statements
 -}

module Language.SystemVerilog.AST.Stmt
    ( Stmt   (..)
    , Timing (..)
    , Sense  (..)
    , CaseKW (..)
    , Case
    , ActionBlock  (..)
    , PropExpr     (..)
    , SeqMatchItem
    , SeqExpr      (..)
    , AssertionItem
    , AssertionExpr
    , Assertion    (..)
    , PropertySpec (..)
    , UniquePriority (..)
    , BlockKW (..)
    ) where

import Text.Printf (printf)

import Language.SystemVerilog.AST.ShowHelp (commas, indent, unlines', showPad)
import Language.SystemVerilog.AST.Attr (Attr)
import Language.SystemVerilog.AST.Decl (Decl)
import Language.SystemVerilog.AST.Expr (Expr, Args(..))
import Language.SystemVerilog.AST.LHS (LHS)
import Language.SystemVerilog.AST.Op (AsgnOp(AsgnOpEq))
import Language.SystemVerilog.AST.Type (Identifier)

data Stmt
    = StmtAttr Attr Stmt
    | Block   BlockKW Identifier [Decl] [Stmt]
    | Case    (Maybe UniquePriority) CaseKW Expr [Case] (Maybe Stmt)
    | For     (Either [Decl] [(LHS, Expr)]) Expr [(LHS, AsgnOp, Expr)] Stmt
    | AsgnBlk AsgnOp LHS Expr
    | Asgn    (Maybe Timing) LHS Expr
    | While   Expr Stmt
    | RepeatL Expr Stmt
    | DoWhile Expr Stmt
    | Forever Stmt
    | Foreach Identifier [Maybe Identifier] Stmt
    | If      (Maybe UniquePriority) Expr Stmt Stmt
    | Timing  Timing Stmt
    | Return  Expr
    | Subroutine Expr Args
    | Trigger Bool Identifier
    | Assertion Assertion
    | Continue
    | Break
    | Null
    deriving Eq

instance Show Stmt where
    show (StmtAttr attr stmt) = printf "%s\n%s" (show attr) (show stmt)
    show (Block kw name decls stmts) =
        printf "%s%s\n%s\n%s" (show kw) header body (blockEndToken kw)
        where
            header = if null name then "" else " : " ++ name
            bodyLines = (map show decls) ++ (map show stmts)
            body = indent $ unlines' bodyLines
    show (Case u kw e cs def) =
        printf "%s%s (%s)\n%s%s\nendcase" (maybe "" showPad u) (show kw) (show e) bodyStr defStr
        where
            bodyStr = indent $ unlines' $ map showCase cs
            defStr = case def of
                Nothing -> ""
                Just c -> printf "\n\tdefault: %s" (show c)
    show (For inits cond assigns stmt) =
        printf "for (%s; %s; %s)\n%s"
            (showInits inits)
            (show cond)
            (commas $ map showAssign assigns)
            (indent $ show stmt)
        where
            showInits :: Either [Decl] [(LHS, Expr)] -> String
            showInits (Left decls) = commas $ map (init . show) decls
            showInits (Right asgns) = commas $ map showInit asgns
                where showInit (l, e) = showAssign (l, AsgnOpEq, e)
            showAssign :: (LHS, AsgnOp, Expr) -> String
            showAssign (l, op, e) = printf "%s %s %s" (show l) (show op) (show e)
    show (Subroutine e a) = printf "%s%s;" (show e) aStr
        where aStr = if a == Args [] [] then "" else show a
    show (AsgnBlk o v e) = printf "%s %s %s;" (show v) (show o) (show e)
    show (Asgn    t v e) = printf "%s <= %s%s;" (show v) (maybe "" showPad t) (show e)
    show (While   e s) = printf  "while (%s) %s" (show e) (show s)
    show (RepeatL e s) = printf "repeat (%s) %s" (show e) (show s)
    show (DoWhile e s) = printf "do %s while (%s);" (show s) (show e)
    show (Forever s  ) = printf "forever %s" (show s)
    show (Foreach x i s) = printf "foreach (%s [ %s ]) %s" x (commas $ map (maybe "" id) i) (show s)
    show (If u a b Null) = printf "%sif (%s)%s"         (maybe "" showPad u) (show a) (showBranch b)
    show (If u a b c   ) = printf "%sif (%s)%s\nelse%s" (maybe "" showPad u) (show a) (showBranch b) (showElseBranch c)
    show (Return e   ) = printf "return %s;" (show e)
    show (Timing t s ) = printf "%s%s" (show t) (showShortBranch s)
    show (Trigger b x) = printf "->%s %s;" (if b then "" else ">") x
    show (Assertion a) = show a
    show (Continue   ) = "continue;"
    show (Break      ) = "break;"
    show (Null       ) = ";"

showBranch :: Stmt -> String
showBranch (block @ Block{}) = ' ' : show block
showBranch stmt = '\n' : (indent $ show stmt)

showElseBranch :: Stmt -> String
showElseBranch (stmt @ If{}) = ' ' : show stmt
showElseBranch stmt = showBranch stmt

showShortBranch :: Stmt -> String
showShortBranch (stmt @ AsgnBlk{}) = ' ' : show stmt
showShortBranch (stmt @ Asgn{}) = ' ' : show stmt
showShortBranch stmt = showBranch stmt

showCase :: ([Expr], Stmt) -> String
showCase (a, b) = printf "%s:%s" (commas $ map show a) (showShortBranch b)

data CaseKW
    = CaseN
    | CaseZ
    | CaseX
    deriving Eq

instance Show CaseKW where
    show CaseN = "case"
    show CaseZ = "casez"
    show CaseX = "casex"

type Case = ([Expr], Stmt)

data Timing
    = Event Sense
    | Delay Expr
    | Cycle Expr
    deriving Eq

instance Show Timing where
    show (Event s) = printf  "@(%s)" (show s)
    show (Delay e) = printf  "#(%s)" (show e)
    show (Cycle e) = printf "##(%s)" (show e)

data Sense
    = Sense        LHS
    | SenseOr      Sense Sense
    | SensePosedge LHS
    | SenseNegedge LHS
    | SenseStar
    deriving Eq

instance Show Sense where
    show (Sense        a  ) = show a
    show (SenseOr      a b) = printf "%s or %s" (show a) (show b)
    show (SensePosedge a  ) = printf "posedge %s" (show a)
    show (SenseNegedge a  ) = printf "negedge %s" (show a)
    show (SenseStar       ) = "*"

data ActionBlock
    = ActionBlockIf   Stmt
    | ActionBlockElse (Maybe Stmt) Stmt
    deriving Eq
instance Show ActionBlock where
    show (ActionBlockIf   Null        ) = ";"
    show (ActionBlockIf   s           ) = printf " %s" (show s)
    show (ActionBlockElse Nothing   s ) = printf " else %s" (show s)
    show (ActionBlockElse (Just s1) s2) = printf " %s else %s" (show s1) (show s2)

data PropExpr
    = PropExpr SeqExpr
    | PropExprImpliesO  SeqExpr PropExpr
    | PropExprImpliesNO SeqExpr PropExpr
    | PropExprFollowsO  SeqExpr PropExpr
    | PropExprFollowsNO SeqExpr PropExpr
    | PropExprIff PropExpr PropExpr
    deriving Eq
instance Show PropExpr where
    show (PropExpr se) = show se
    show (PropExprImpliesO  a b) = printf "(%s |-> %s)" (show a) (show b)
    show (PropExprImpliesNO a b) = printf "(%s |=> %s)" (show a) (show b)
    show (PropExprFollowsO  a b) = printf "(%s #-# %s)" (show a) (show b)
    show (PropExprFollowsNO a b) = printf "(%s #=# %s)" (show a) (show b)
    show (PropExprIff a b) = printf "(%s and %s)" (show a) (show b)
type SeqMatchItem = Either (LHS, AsgnOp, Expr) (Identifier, Args)
data SeqExpr
    = SeqExpr Expr
    | SeqExprAnd        SeqExpr SeqExpr
    | SeqExprOr         SeqExpr SeqExpr
    | SeqExprIntersect  SeqExpr SeqExpr
    | SeqExprThroughout Expr    SeqExpr
    | SeqExprWithin     SeqExpr SeqExpr
    | SeqExprDelay (Maybe SeqExpr) Expr SeqExpr
    | SeqExprFirstMatch SeqExpr [SeqMatchItem]
    deriving Eq
instance Show SeqExpr where
    show (SeqExpr           a  ) = show a
    show (SeqExprAnd        a b) = printf "(%s %s %s)" (show a) "and"        (show b)
    show (SeqExprOr         a b) = printf "(%s %s %s)" (show a) "or"         (show b)
    show (SeqExprIntersect  a b) = printf "(%s %s %s)" (show a) "intersect"  (show b)
    show (SeqExprThroughout a b) = printf "(%s %s %s)" (show a) "throughout" (show b)
    show (SeqExprWithin     a b) = printf "(%s %s %s)" (show a) "within"     (show b)
    show (SeqExprDelay   me e s) = printf "%s##%s %s" (maybe "" showPad me) (show e) (show s)
    show (SeqExprFirstMatch e a) = printf "first_match(%s, %s)" (show e) (show a)

type AssertionItem = (Maybe Identifier, Assertion)
type AssertionExpr = Either PropertySpec Expr
data Assertion
    = Assert AssertionExpr ActionBlock
    | Assume AssertionExpr ActionBlock
    | Cover  AssertionExpr Stmt
    deriving Eq
instance Show Assertion where
    show (Assert e a) = printf "assert %s%s" (showAssertionExpr e) (show a)
    show (Assume e a) = printf "assume %s%s" (showAssertionExpr e) (show a)
    show (Cover  e a) = printf  "cover %s%s" (showAssertionExpr e) (show a)

showAssertionExpr :: AssertionExpr -> String
showAssertionExpr (Left e) = printf "property (%s\n)" (show e)
showAssertionExpr (Right e) = printf "(%s)" (show e)

data PropertySpec
    = PropertySpec (Maybe Sense) (Maybe Expr) PropExpr
    deriving Eq
instance Show PropertySpec where
    show (PropertySpec ms me pe) =
        printf "%s%s\n\t%s" msStr meStr (show pe)
        where
            msStr = case ms of
                Nothing -> ""
                Just s -> printf "@(%s) " (show s)
            meStr = case me of
                Nothing -> ""
                Just e -> printf "disable iff (%s)" (show e)

data UniquePriority
    = Unique
    | Unique0
    | Priority
    deriving Eq

instance Show UniquePriority where
    show Unique   = "unique"
    show Unique0  = "unique0"
    show Priority = "priority"

data BlockKW
    = Seq
    | Par
    deriving Eq

instance Show BlockKW where
    show Seq = "begin"
    show Par = "fork"

blockEndToken :: BlockKW -> Identifier
blockEndToken Seq = "end"
blockEndToken Par = "join"
