module FxFlow
(
  -- * Accessor
  spawn,
  -- * Spawner
  Spawner,
  react,
  -- * Flow
  Flow,
)
where

import FxFlow.Prelude
import qualified Fx
import qualified FxStreaming.Producer as Producer


-- * Producer
-------------------------

spawn :: (SomeException -> err) -> Producer env err inp -> Spawner env err (inp -> Flow out) -> Producer env err out
spawn someExceptionErr (Producer inpEio) (Spawner flowReader) = Producer $ \ env stopOut emitOut -> do

  result <- bimap1 someExceptionErr $ liftIO $ do

    outChan <- newTQueueIO
    finishedVar <- newTVarIO False
    errVar <- newEmptyTMVarIO
    let reportErr = atomically . void . tryPutTMVar errVar

    -- Spawn all the flow workers:
    (flowByInp, stopSignallers) <- runStateT (runReaderT flowReader (env, reportErr)) []

    -- Spawn the producer:
    forkIO $ do
      producerResult <- let
        stop = bimap1 someExceptionErr $ liftIO $ atomically (writeTVar finishedVar True)
        emit inp = let
          Flow reg = flowByInp inp
          in do
            pushingResult <- bimap1 someExceptionErr $ liftIO $ atomically $
              (Just <$> readTMVar errVar) <|>
              (Nothing <$ reg (writeTQueue outChan))
            case pushingResult of
              Just err -> throwError (either someExceptionErr id err)
              Nothing -> return ()
        in runExceptT (Fx.eio (inpEio env stop emit))
      case producerResult of
        Right () -> return ()
        Left err -> reportErr (Right err)
    return (outChan, finishedVar, errVar)

    -- Feed the consumer:
    fix $ \ loop -> join $ atomically $ asum $
      [
        do
          err <- readTMVar errVar
          return (return (Left (either someExceptionErr id err)))
        ,
        do
          out <- readTQueue outChan
          return $ do
            emissionResult <- runExceptT $ Fx.eio $ emitOut out
            case emissionResult of
              Right () -> loop
              Left err -> return (Left err)
        ,
        do
          finished <- readTVar finishedVar
          if finished
            then return $ do
              mconcat stopSignallers
              runExceptT $ Fx.eio $ stopOut
            else retry
      ]

  either throwError return result


-- * Spawner
-------------------------

{-|
Context for spawning of actors.
-}
newtype Spawner env err a = Spawner (ReaderT (env, Either SomeException err -> IO ()) (StateT [IO ()] IO) a)
  deriving (Functor, Applicative, Monad)

{-|
Spawn a reactor with an input message buffer of size limited to the specified size,
producing a flow, which outputs results.
-}
react :: Int -> (inp -> Accessor env err out) -> Spawner env err (inp -> Flow out)
react taskQueueSize step = Spawner $ ReaderT $ \ (env, reportErr) -> StateT $ \ priorKillers -> do
  taskQueue <- newTBQueueIO (fromIntegral taskQueueSize)
  deathLockVar <- newEmptyMVar
  forkIO $ fix $ \ loop -> do
    task <- atomically $ readTBQueue taskQueue
    case task of
      Just (inp, emit) -> do
        errOrOut <- Fx.uio $ runExceptT $ Fx.eio $ Fx.providerAndAccessor (pure env) $ step inp
        case errOrOut of
          Right out -> do
            atomically (emit out)
            loop
          Left err -> do
            reportErr (Right err)
            tryPutMVar deathLockVar () $> ()
      Nothing -> tryPutMVar deathLockVar () $> ()
  let
    flow inp = Flow (\ emit -> writeTBQueue taskQueue (Just (inp, emit)))
    kill = do
      atomically (writeTBQueue taskQueue Nothing)
      readMVar deathLockVar
    newKillers = kill : priorKillers
    in return (flow, newKillers)


-- * Flow
-------------------------

{-|
Actor communication network composition.
Specifies the message flow between them.
-}
newtype Flow a =
  {-|
  Action registering a callback.

  The idea is that the outer action is lightweight
  it deals with composition and message registration.
  The continuation action is lightweight aswell,
  it just gets executed on a different thread some time later on.
  -}
  Flow ((a -> STM ()) -> STM ())
  deriving (Functor)

instance Applicative Flow where
  pure a = Flow (\ emit -> emit a)
  (<*>) (Flow reg1) (Flow reg2) = Flow $ \ emit -> do
    var1 <- newTVar Nothing
    var2 <- newTVar Nothing
    reg1 $ \ out1 -> do
      state2 <- readTVar var2
      case state2 of
        Just out2 -> emit (out1 out2)
        Nothing -> writeTVar var1 (Just out1)
    reg2 $ \ out2 -> do
      state1 <- readTVar var1
      case state1 of
        Just out1 -> emit (out1 out2)
        Nothing -> writeTVar var2 (Just out2)

instance Monad Flow where
  return = pure
  (>>=) (Flow reg1) k2 = Flow $ \ emit -> reg1 $ k2 >>> \ (Flow reg2) -> reg2 emit

instance Alternative Flow where
  empty = Flow (\ emit -> return ())
  (<|>) (Flow reg1) (Flow reg2) = Flow $ \ emit -> reg1 emit *> reg2 emit

instance MonadPlus Flow where
  mzero = empty
  mplus = (<|>)
