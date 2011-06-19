module Rx where

import Control.Monad
import Control.Concurrent.STM
import Control.Concurrent.STM.TVar
import Data.IORef

data Observable a = Observable { subscribe :: Subscribe a }

data Observer a = Observer { consume :: EventHandler a }

type EventHandler a = (Event a -> IO ())

data Event a = Next a | End | Error String

type Subscribe a = (Observer a -> IO Disposable)

type Disposable = IO ()

class Source s where
  getObservable :: s a -> Observable a

instance Functor Observable where
  fmap = select

instance Monad Observable where
  return a = observableList [a]
  (>>=) = selectMany

instance MonadPlus Observable where
  mzero = observableList []
  mplus = merge 

toObservable :: Subscribe a -> Observable a
toObservable subscribe = Observable subscribe

toObserver :: (a -> IO()) -> Observer a
toObserver next = Observer defaultHandler
  where defaultHandler (Next a) = next a
        defaultHandler End = return ()
        defaultHandler (Error e) = fail e

observableList :: [a] -> Observable a
observableList list = toObservable subscribe 
  where subscribe observer = do mapM (consume observer) (map Next list)
                                consume observer $ End
                                return (return ())

select :: (a -> b) -> Observable a -> Observable b
select convert source = do a <- source
                           return $ convert a

filter :: (a -> Bool) -> Observable a -> Observable a
filter predicate source = do 
  a <- source
  if (predicate a) then return a else mzero

selectMany :: Observable a -> (a -> Observable b) -> Observable b
selectMany source spawner = toObservable ((subscribe source) . spawningObserver)
  where spawningObserver observer = toObserver $ spawnSingle observer 
        spawnSingle observer a = subscribe (spawner a) (ignoreEnd observer) >> return ()
        ignoreEnd observer = onEnd observer $ return ()
        -- TODO: error handling 
        {- TODO: dispose will never be called on the spawned Observables -}
concat :: Observable a -> Observable a -> Observable a
concat a' b' = toObservable concat'
  where concat' observer = do disposeRef <- newIORef (return ())
                              disposeFunc <- subscribe a' $ onEnd observer $ switchToB disposeRef observer
                              {- TODO: what if subscribe call leads to immediate call to end. now the following line will override dispose-b with dispose-a -}
                              writeIORef disposeRef disposeFunc
                              return $ (join . readIORef) disposeRef 
        switchToB disposeRef observer = subscribe b' observer >>= (writeIORef disposeRef)

onEnd :: Observer a -> IO() -> Observer a
onEnd observer action = Observer onEnd'
  where onEnd' End = action
        onEnd' event = consume observer event

onNext :: Observer a -> (a -> IO()) -> Observer a
onNext observer action = Observer onNext'
  where onNext' (Next a) = action a
        onNext' event = consume observer event
 
merge :: Observable a -> Observable a -> Observable a
merge left right = toObservable merge'
  where merge' observer = do endLeft <- newIORef (False)
                             endRight <- newIORef (False)
                             disposeLeft <- subscribe left $ onEnd observer $ barrier endLeft endRight observer
                             disposeRight <- subscribe right $ onEnd observer $ barrier endRight endLeft observer
                             return (disposeLeft >> disposeRight)
        barrier myFlag otherFlag observer = do writeIORef myFlag True
                                               otherDone <- readIORef otherFlag
                                               when otherDone $ consume observer End

takeWhile :: (a -> Bool) -> Observable a -> Observable a
takeWhile condition source = stateful takeWhile' False source
  where takeWhile' state event@(Next a) = do done <- readTVar state
                                             if done 
                                                then return Skip
                                                else if condition a
                                                    then return (Pass event)
                                                    else writeTVar state True >> return Unsubscribe
        takeWhile' state event = do done <- readTVar state
                                    if (done) then (return Skip) else (return $ Pass event)

skipWhile :: (a -> Bool) -> Observable a -> Observable a
skipWhile condition source = stateful skipWhile' False source
  where skipWhile' state event@(Next a) = do done <- readTVar state
                                             if (done || not (condition a))
                                                then writeTVar state True >> (return $ Pass event)
                                                else return Skip
        skipWhile' state event = return $ Pass event
takeUntil :: Observable a -> Observable b -> Observable a
takeUntil source stopper = toObservable subscribe'
  where subscribe' observer = do state <- newTVarIO True
                                 disposeSource <- subscribeStatefully whileOpen state source observer
                                 disposeStopper <- subscribeStatefully stopOnNext state stopper observer
                                 return (disposeSource >> disposeStopper)
        whileOpen  state event = do open <- readTVar state
                                    if (not open) then return Unsubscribe else return $ Pass event
        stopOnNext state (Next _) = do open <- readTVar state
                                       if (not open) 
                                          then return Skip 
                                          else writeTVar state False >> return Unsubscribe
        stopOnNext state _ = return Skip
 
data Result a = Pass (Event a) | Skip | Unsubscribe

stateful :: (TVar s -> Event a -> STM (Result a)) -> s -> Observable a -> Observable a
stateful processor initState source = toObservable subscribe'
  where subscribe' observer = do state <- newTVarIO initState
                                 subscribeStatefully processor state source observer

subscribeStatefully :: (TVar s -> Event a -> STM (Result b)) -> TVar s -> Observable a -> Observer b -> IO Disposable
subscribeStatefully processor state source observer = subscribe source $ Observer $ statefully observer state
  where statefully observer state event = do result <- atomically (processor state event)
                                             case result of
                                                Pass e -> consume observer e
                                                Skip -> return()
                                                Unsubscribe -> consume observer End 
-- TODO: implement the Unsubscribe case above 

data Valve a = Valve (TVar Bool) (Observable a) 

valve :: Observable a -> Bool -> STM (Valve a)
valve observable open = newTVar open >>= return . (flip Valve) observable

openValve :: Valve a -> STM ()
openValve = setValveState True 

closeValve :: Valve a -> STM()
closeValve = setValveState False

setValveState :: Bool -> Valve a -> STM ()
setValveState newState (Valve state _) = writeTVar state newState

instance Source Valve where
  getObservable (Valve state (Observable subscribe)) = toObservable subscribe'
    where subscribe' = subscribe . valvedObserver state

valved :: TVar Bool -> Observable a -> Observable a
valved state observable = getObservable $ Valve state observable

valvedObserver :: TVar Bool -> Observer a -> Observer a
valvedObserver state (Observer consume) = Observer (valved consume)
  where valved action input = atomically (readTVar state) >>= \open -> when open (action input)

{- TODO: *Until types should be Observable a -> Observable a -> Observable a -}
{- TODO: Use Control.Concurrent.STM -}
