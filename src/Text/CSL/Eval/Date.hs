{-# LANGUAGE PatternGuards #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Text.CSL.Eval.Date
-- Copyright   :  (c) Andrea Rossato
-- License     :  BSD-style (see LICENSE)
--
-- Maintainer  :  Andrea Rossato <andrea.rossato@unitn.it>
-- Stability   :  unstable
-- Portability :  unportable
--
-- The CSL implementation
--
-----------------------------------------------------------------------------

module Text.CSL.Eval.Date where

import Control.Monad.State
import qualified Control.Exception as E

import Data.List
import Data.List.Split

import Text.CSL.Exception
import Text.CSL.Eval.Common
import Text.CSL.Eval.Output
import Text.CSL.Style
import Text.CSL.Reference
import Text.CSL.Util ( toRead, init', last' )
import Text.Pandoc.Definition ( Inline (Str) )
import Text.Printf (printf)

evalDate :: Element -> State EvalState [Output]
evalDate (Date s f fm dl dp dp') = do
  tm <- gets $ terms . env
  k  <- getStringVar "ref-id"
  em <- gets mode
  let updateFM (Formatting aa ab ac ad ae af ag ah ai aj ak al am an ahl)
               (Formatting _  _  bc bd be bf bg bh _  bj bk _ _ _ _) =
                   Formatting aa ab (updateS ac bc)
                                    (updateS ad bd)
                                    (updateS ae be)
                                    (updateS af bf)
                                    (updateS ag bg)
                                    (updateS ah bh)
                                    ai
                                    (updateS aj bj)
                                    (if bk /= ak then bk else ak)
                                    al am an ahl
      updateS a b = if b /= a && b /= [] then b else a
  case f of
    NoFormDate -> mapM getDateVar s >>= return . outputList fm dl .
                  concatMap (formatDate em k tm dp)
    _          -> do Date _ _ lfm ldl ldp _ <- getDate f
                     let go dps = return . outputList (updateFM fm lfm) (if ldl /= [] then ldl else dl) .
                                  concatMap (formatDate em k tm dps)
                         update l x@(DatePart a b c d) =
                             case filter ((==) a . dpName) l of
                               (DatePart _ b' c' d':_) -> DatePart a (updateS  b b')
                                                                     (updateS  c c')
                                                                     (updateFM d d')
                               _                       -> x
                         updateDP = map (update dp) ldp
                         date     = mapM getDateVar s
                     case dp' of
                       "year-month" -> go (filter ((/=) "day"  . dpName) updateDP) =<< date
                       "year"       -> go (filter ((==) "year" . dpName) updateDP) =<< date
                       _            -> go                                updateDP  =<< date

evalDate _ = return []

getDate :: DateForm -> State EvalState Element
getDate f = do
  x <- filter (\(Date _ df _ _ _ _) -> df == f) <$> gets (dates . env)
  case x of
    [x'] -> return x'
    _    -> return $ Date [] NoFormDate emptyFormatting [] [] []

formatDate :: EvalMode -> String -> [CslTerm] -> [DatePart] -> [RefDate] -> [Output]
formatDate em k tm dp date
    | [d]     <- date = concatMap (formatDatePart False d) dp
    | (a:b:_) <- date = addODate . concat $ doRange a b
    | otherwise       = []
    where
      addODate []   = []
      addODate xs   = [ODate xs]
      splitDate a b = case split (onSublist $ diff a b dp) dp of
                        [x,y,z] -> (x,y,z)
                        _       -> E.throw ErrorSplittingDate
      doRange   a b = let (x,y,z) = splitDate a b in
                      map (formatDatePart False  a) x ++
                      map (formatDatePart False  a) (init' y) ++
                      map (formatDatePart True   a) (last' y) ++
                      map (formatDatePart False  b) y ++
                      map (formatDatePart False  b) z
      diff  a b = filter (flip elem (diffDate a b) . dpName)
      diffDate (RefDate ya ma sa da _ _)
               (RefDate yb mb sb db _ _) = case () of
                                             _ | ya /= yb  -> ["year","month","day"]
                                               | ma /= mb  ->
                                                 if da == Nothing && db == Nothing
                                                    then ["month"]
                                                    else ["month","day"]
                                               | da /= db  -> ["day"]
                                               | sa /= sb  -> ["month"]
                                               | otherwise -> ["year","month","day"]

      term f t = let f' = if f `elem` ["verb", "short", "verb-short", "symbol"]
                          then read $ toRead f
                          else Long
                 in maybe [] termPlural $ findTerm t f' tm

      formatDatePart False (RefDate y m e d _ _) (DatePart n f _ fm)
          | "year"  <- n, y /= Nothing = return $ OYear (formatYear  f    y) k fm
          | "month" <- n, m /= Nothing = output fm      (formatMonth f fm m)
          | "day"   <- n, d /= Nothing = output fm      (formatDay   f m  d)
          | "month" <- n, m == Nothing
                        , e /= Nothing = output fm $
                                          term f ("season-0" ++ maybe "" show e)

      formatDatePart True (RefDate y m e d _ _) (DatePart n f rd fm)
          | "year"  <- n, y /= Nothing = OYear (formatYear  f y) k (fm {suffix = []}) : formatDelim
          | "month" <- n, m /= Nothing = output (fm {suffix = []}) (formatMonth f fm m) ++ formatDelim
          | "day"   <- n, d /= Nothing = output (fm {suffix = []}) (formatDay   f m  d) ++ formatDelim
          | "month" <- n, m == Nothing
                        , e /= Nothing = output (fm {suffix = []}) (term f $ "season-0" ++ maybe "" show e) ++ formatDelim
          where
            formatDelim = if rd == "-" then [OPan [Str "\x2013"]] else [OPan [Str rd]]

      formatDatePart _ (RefDate _ _ _ _ (Literal o) _) (DatePart n _ _ fm)
          | "year"  <- n, o /= mempty = output fm o
          | otherwise                 = []

      formatYear _ Nothing = ""
      formatYear f (Just y)
          | "short" <- f = printf "%02d" (y `mod` 100)
          | isSorting em
          , y < 0        = printf "-%04d" (abs y)
          | isSorting em = printf "%04d" y
          | y < 0        = printf "%d" (abs y) ++ term [] "bc"
          | y < 1000
          , y > 0        = printf "%d" y ++ term [] "ad"
          | y == 0       = ""
          | otherwise    = printf "%d" y

      formatMonth _ _ Nothing = ""
      formatMonth f fm (Just m)
          | "short"   <- f = getMonth $ period . termPlural
          | "long"    <- f = getMonth termPlural
          | "numeric" <- f = printf "%d" m
          | otherwise      = printf "%02d" m
          where
            period     = if stripPeriods fm then filter (/= '.') else id
            getMonth g = maybe (show m) g $ findTerm ("month-" ++ printf "%02d" m) (read $ toRead f) tm

      formatDay _ _ Nothing = ""
      formatDay f m (Just d)
          | "numeric-leading-zeros" <- f = printf "%02d" d
          | "ordinal"               <- f = ordinal tm ("month-" ++ maybe "0" (printf "%02d") m) d
          | otherwise                    = printf "%d" d

ordinal :: [CslTerm] -> String -> Int -> String
ordinal ts v s
    | s < 10        = let a = termPlural (getWith1 (show s)) in
                      if  a == [] then setOrd (term []) else show s ++ a
    | s < 100       = let a = termPlural (getWith2 (show s))
                          b = getWith1 [last (show s)] in
                      if  a /= []
                      then show s ++ a
                      else if termPlural b == [] || (termMatch b /= [] && termMatch b /= "last-digit")
                           then setOrd (term []) else setOrd b
    | otherwise     = let a = getWith2  last2
                          b = getWith1 [last (show s)] in
                      if termPlural a /= [] && termMatch a /= "whole-number"
                      then setOrd a
                      else if termPlural b == [] || (termMatch b /= [] && termMatch b /= "last-digit")
                           then setOrd (term []) else setOrd b
    where
      setOrd   = (++) (show s) . termPlural
      getWith1 = term . (++) "-0"
      getWith2 = term . (++) "-"
      last2    = reverse . take 2 . reverse $ show s
      term   t = getOrdinal v ("ordinal" ++ t) ts

longOrdinal :: [CslTerm] -> String -> Int -> String
longOrdinal ts v s
    | s > 10 ||
      s == 0  = ordinal ts v s
    | otherwise = case s `mod` 10 of
                    1 -> term "01"
                    2 -> term "02"
                    3 -> term "03"
                    4 -> term "04"
                    5 -> term "05"
                    6 -> term "06"
                    7 -> term "07"
                    8 -> term "08"
                    9 -> term "09"
                    _ -> term "10"
    where
      term t = termPlural $ getOrdinal v ("long-ordinal-" ++ t) ts

getOrdinal :: String -> String -> [CslTerm] -> CslTerm
getOrdinal v s ts
    = case findTerm' s Long gender ts of
        Just  x -> x
        Nothing -> case findTerm' s Long Neuter ts of
                     Just  x -> x
                     Nothing -> newTerm
    where
      gender = if v `elem` numericVars || "month" `isPrefixOf` v
               then maybe Neuter termGender $ findTerm v Long ts
               else Neuter

