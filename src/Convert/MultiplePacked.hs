{- sv2v
 - Author: Zachary Snow <zach@zachjs.com>
 -
 - Conversion for flattening variables with multiple packed dimensions
 -
 - This removes one packed dimension per identifier per pass. This works fine
 - because all conversions are repeatedly applied.
 -
 - We previously had a very complex conversion which used `generate` to make
 - flattened and unflattened versions of the array as necessary. This has now
 - been "simplified" to always flatten the array, and then rewrite all usages of
 - the array as appropriate.
 -
 - A previous iteration of this conversion aggressively flattened all dimensions
 - (even if unpacked) in any multidimensional data declaration. This had the
 - unfortunate side effect of packing memories, which could hinder efficient
 - synthesis. Now this conversion only flattens packed dimensions and leaves the
 - (only potentially necessary) movement of dimensions from unpacked to packed
 - to the separate UnpackedArray conversion.
 -
 - Note that the ranges being combined may not be of the form [hi:lo], and need
 - not even be the same direction! Because of this, we have to flip around the
 - indices of certain accesses.
 -}

module Convert.MultiplePacked (convert) where

import Control.Monad.State
import Data.Tuple (swap)
import Data.Maybe (isJust, fromJust)
import qualified Data.Map.Strict as Map

import Convert.Traverse
import Language.SystemVerilog.AST

type Info = Map.Map Identifier ([Range], [Range])

convert :: [AST] -> [AST]
convert = map $ traverseDescriptions convertDescription

convertDescription :: Description -> Description
convertDescription =
    scopedConversion traverseDeclM traverseModuleItemM traverseStmtM Map.empty

-- collects and converts declarations with multiple packed dimensions
traverseDeclM :: Decl -> State Info Decl
traverseDeclM (Variable dir t ident a me) = do
    t' <- traverseTypeM t a ident
    return $ Variable dir t' ident a me
traverseDeclM (Param s t ident e) = do
    t' <- traverseTypeM t [] ident
    return $ Param s t' ident e
traverseDeclM (ParamType s ident mt) =
    return $ ParamType s ident mt

traverseTypeM :: Type -> [Range] -> Identifier -> State Info Type
traverseTypeM t a ident = do
    let (tf, rs) = typeRanges t
    if length rs <= 1
        then do
            modify $ Map.delete ident
            return t
        else do
            modify $ Map.insert ident (rs, a)
            let r1 : r2 : rest = rs
            let rs' = (combineRanges r1 r2) : rest
            return $ tf rs'

-- combines two ranges into one flattened range
combineRanges :: Range -> Range -> Range
combineRanges r1 r2 = r
    where
        rYY = combine r1 r2
        rYN = combine r1 (swap r2)
        rNY = combine (swap r1) r2
        rNN = combine (swap r1) (swap r2)
        rY = endianCondRange r2 rYY rYN
        rN = endianCondRange r2 rNY rNN
        r = endianCondRange r1 rY rN

        combine :: Range -> Range -> Range
        combine (s1, e1) (s2, e2) =
            (simplify upper, simplify lower)
            where
                size1 = rangeSize (s1, e1)
                size2 = rangeSize (s2, e2)
                lower = BinOp Add e2 (BinOp Mul e1 size2)
                upper = BinOp Add (BinOp Mul size1 size2)
                            (BinOp Sub lower (Number "1"))

traverseModuleItemM :: ModuleItem -> State Info ModuleItem
traverseModuleItemM item =
    traverseLHSsM  traverseLHSM  item >>=
    traverseExprsM traverseExprM

traverseStmtM :: Stmt -> State Info Stmt
traverseStmtM stmt =
    traverseStmtLHSsM  traverseLHSM  stmt >>=
    traverseStmtExprsM traverseExprM

traverseExprM :: Expr -> State Info Expr
traverseExprM = traverseNestedExprsM $ stately traverseExpr

-- LHSs need to be converted too. Rather than duplicating the procedures, we
-- turn LHSs into expressions temporarily and use the expression conversion.
traverseLHSM :: LHS -> State Info LHS
traverseLHSM lhs = do
    let expr = lhsToExpr lhs
    expr' <- traverseExprM expr
    return $ fromJust $ exprToLHS expr'

traverseExpr :: Info -> Expr -> Expr
traverseExpr typeDims =
    rewriteExpr
    where
        -- removes the innermost dimensions of the given packed and unpacked
        -- dimensions, and applies the given transformation to the expression
        dropLevel
            :: (Expr -> Expr)
            -> ([Range], [Range], Expr)
            -> ([Range], [Range], Expr)
        dropLevel nest ([], [], expr) =
            ([], [], nest expr)
        dropLevel nest (packed, [], expr) =
            (tail packed, [], nest expr)
        dropLevel nest (packed, unpacked, expr) =
            (packed, tail unpacked, nest expr)

        -- given an expression, returns the packed and unpacked dimensions and a
        -- tagged version of the expression, if possible
        levels :: Expr -> Maybe ([Range], [Range], Expr)
        levels (Ident x) =
            case Map.lookup x typeDims of
                Just (a, b) -> Just (a, b, Ident $ tag : x)
                Nothing -> Nothing
        levels (Bit expr a) =
            fmap (dropLevel $ \expr' -> Bit expr' a) (levels expr)
        levels (Range expr a b) =
            fmap (dropLevel $ \expr' -> Range expr' a b) (levels expr)
        levels _ = Nothing

        -- given an expression, returns the two innermost packed dimensions and a
        -- tagged version of the expression, if possible
        dims :: Expr -> Maybe (Range, Range, Expr)
        dims expr =
            case levels expr of
                Just (dimInner : dimOuter : _, [], expr') ->
                    Just (dimInner, dimOuter, expr')
                _ -> Nothing

        -- if the given range is flipped, the result will flip around the given
        -- indexing expression
        orientIdx :: Range -> Expr -> Expr
        orientIdx r e =
            endianCondExpr r e eSwapped
            where
                eSwapped = BinOp Sub (snd r) (BinOp Sub e (fst r))

        -- Converted idents are prefixed with an invalid character to ensure
        -- that are not converted twice when the traversal steps downward. When
        -- the prefixed identifier is encountered at the lowest level, it is
        -- removed.

        tag = ':'

        rewriteExpr :: Expr -> Expr
        rewriteExpr (Ident x) =
            if head x == tag
                then Ident $ tail x
                else Ident x
        rewriteExpr (orig @ (Bit (Bit expr idxInner) idxOuter)) =
            if isJust maybeDims
                then Bit expr' idx'
                else orig
            where
                maybeDims = dims $ rewriteExpr expr
                Just (dimInner, dimOuter, expr') = maybeDims
                idxInner' = orientIdx dimInner idxInner
                idxOuter' = orientIdx dimOuter idxOuter
                base = BinOp Mul idxInner' (rangeSize dimOuter)
                idx' = simplify $ BinOp Add base idxOuter'
        rewriteExpr (orig @ (Bit expr idx)) =
            if isJust maybeDims
                then Range expr' mode' range'
                else orig
            where
                maybeDims = dims $ rewriteExpr expr
                Just (dimInner, dimOuter, expr') = maybeDims
                mode' = IndexedPlus
                idx' = orientIdx dimInner idx
                len = rangeSize dimOuter
                base = BinOp Add (endianCondExpr dimOuter (snd dimOuter) (fst dimOuter)) (BinOp Mul idx' len)
                range' = (simplify base, simplify len)
        rewriteExpr (orig @ (Range (Bit expr idxInner) modeOuter rangeOuter)) =
            if isJust maybeDims
                then Range expr' mode' range'
                else orig
            where
                maybeDims = dims $ rewriteExpr expr
                Just (dimInner, dimOuter, expr') = maybeDims
                mode' = IndexedPlus
                idxInner' = orientIdx dimInner idxInner
                rangeOuterReverseIndexed =
                    (BinOp Add (fst rangeOuter) (BinOp Sub (snd rangeOuter)
                    (Number "1")), snd rangeOuter)
                (baseOuter, lenOuter) =
                    case modeOuter of
                        IndexedPlus ->
                            endianCondRange dimOuter rangeOuter rangeOuterReverseIndexed
                        IndexedMinus ->
                            endianCondRange dimOuter rangeOuterReverseIndexed rangeOuter
                        NonIndexed ->
                            (endianCondExpr dimOuter (snd rangeOuter) (fst rangeOuter), rangeSize rangeOuter)
                idxOuter' = orientIdx dimOuter baseOuter
                start = BinOp Mul idxInner' (rangeSize dimOuter)
                base = simplify $ BinOp Add start idxOuter'
                len = lenOuter
                range' = (base, len)
        rewriteExpr (orig @ (Range expr mode range)) =
            if isJust maybeDims
                then Range expr' mode' range'
                else orig
            where
                maybeDims = dims $ rewriteExpr expr
                Just (_, dimOuter, expr') = maybeDims
                mode' = mode
                size = rangeSize dimOuter
                base = endianCondExpr dimOuter (snd dimOuter) (fst dimOuter)
                range' =
                    case mode of
                        NonIndexed   ->
                            (simplify hi, simplify lo)
                            where
                                lo = BinOp Mul size (snd range)
                                hi = BinOp Sub (BinOp Add lo (BinOp Mul (rangeSize range) size)) (Number "1")
                        IndexedPlus  -> (BinOp Add (BinOp Mul size (fst range)) base, BinOp Mul size (snd range))
                        IndexedMinus -> (BinOp Add (BinOp Mul size (fst range)) base, BinOp Mul size (snd range))
        rewriteExpr other = other
