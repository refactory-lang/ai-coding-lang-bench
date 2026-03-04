{-# LANGUAGE ForeignFunctionInterface #-}
module Main where

import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesDirectoryExist)
import System.Exit (exitFailure)
import Data.Word (Word64, Word8)
import Data.Bits (xor)
import Data.List (sort)
import qualified Data.ByteString as BS
import Numeric (showHex)
import Foreign.C.Types (CTime(..))
import Foreign.Ptr (Ptr, nullPtr)

foreign import ccall unsafe "time" c_time :: Ptr () -> IO CTime

miniHash :: BS.ByteString -> String
miniHash bs = padHex 16 (go 1469598103934665603 (BS.unpack bs))
  where
    go :: Word64 -> [Word8] -> Word64
    go h [] = h
    go h (b:rest) =
      let h1 = h `xor` fromIntegral b
          h2 = h1 * 1099511628211
      in go h2 rest
    padHex :: Int -> Word64 -> String
    padHex n v =
      let hex = showHex v ""
      in replicate (n - length hex) '0' ++ hex

minigitDir :: FilePath
minigitDir = ".minigit"

objectsDir :: FilePath
objectsDir = ".minigit/objects"

commitsDir :: FilePath
commitsDir = ".minigit/commits"

indexFile :: FilePath
indexFile = ".minigit/index"

headFile :: FilePath
headFile = ".minigit/HEAD"

cmdInit :: IO ()
cmdInit = do
    exists <- doesDirectoryExist minigitDir
    if exists
        then putStrLn "Repository already initialized"
        else do
            createDirectoryIfMissing True objectsDir
            createDirectoryIfMissing True commitsDir
            writeFile indexFile ""
            writeFile headFile ""

cmdAdd :: String -> IO ()
cmdAdd filename = do
    exists <- doesFileExist filename
    if not exists
        then do
            putStrLn "File not found"
            exitFailure
        else do
            content <- BS.readFile filename
            let hash = miniHash content
            BS.writeFile (objectsDir ++ "/" ++ hash) content
            idxContent <- readFile indexFile
            let entries = filter (not . null) (lines idxContent)
            if filename `elem` entries
                then return ()
                else writeFile indexFile (unlines (entries ++ [filename]))

cmdCommit :: String -> IO ()
cmdCommit message = do
    idxContent <- readFile indexFile
    let entries = filter (not . null) (lines idxContent)
    if null entries
        then do
            putStrLn "Nothing to commit"
            exitFailure
        else do
            headContent <- readFile headFile
            let parent = if null headContent then "NONE" else headContent
            CTime t <- c_time nullPtr
            let timestamp = show (fromIntegral t :: Integer)
            let sortedFiles = sort entries
            fileLines <- mapM (\f -> do
                content <- BS.readFile f
                let h = miniHash content
                return (f ++ " " ++ h)
                ) sortedFiles
            let commitContent = "parent: " ++ parent ++ "\n"
                             ++ "timestamp: " ++ timestamp ++ "\n"
                             ++ "message: " ++ message ++ "\n"
                             ++ "files:\n"
                             ++ unlines fileLines
            let commitHash = miniHash (strToBS commitContent)
            writeFile (commitsDir ++ "/" ++ commitHash) commitContent
            writeFile headFile commitHash
            writeFile indexFile ""
            putStrLn ("Committed " ++ commitHash)

cmdLog :: IO ()
cmdLog = do
    headContent <- readFile headFile
    if null headContent
        then putStrLn "No commits"
        else printLog headContent

printLog :: String -> IO ()
printLog hash = do
    content <- readFile (commitsDir ++ "/" ++ hash)
    let ls = lines content
        parent = drop 8 (ls !! 0)
        timestamp = drop 11 (ls !! 1)
        msg = drop 9 (ls !! 2)
    putStrLn ("commit " ++ hash)
    putStrLn ("Date: " ++ timestamp)
    putStrLn ("Message: " ++ msg)
    if parent /= "NONE"
        then do
            putStrLn ""
            printLog parent
        else return ()

strToBS :: String -> BS.ByteString
strToBS = BS.pack . map (fromIntegral . fromEnum)

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["init"] -> cmdInit
        ["add", file] -> cmdAdd file
        ["commit", "-m", msg] -> cmdCommit msg
        ["log"] -> cmdLog
        _ -> do
            putStrLn "Unknown command"
            exitFailure
